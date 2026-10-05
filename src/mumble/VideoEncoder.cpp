// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "VideoEncoder.h"

#include "Log.h"
#include "Global.h"

#include <QtCore/QMutexLocker>
#include <QtCore/QTimer>

#include <algorithm>

static constexpr int VIDEO_GOP_SIZE = 5 * VideoEncoder::FPS; // keyframe every ~5 s — receivers request them on loss
/// Minimum time between a key frame and one sent on request. Viewers tend to lose the same packets and each of
/// them asks for a key frame, so this keeps a single loss from causing a burst of key frames.
static constexpr qint64 MIN_KEYFRAME_REQUEST_INTERVAL_US = 500'000;

VideoEncoder::VideoEncoder(QObject *parent) : QObject(parent) {
	// Both timers are children, so they move to the encoder's thread together with it.
	m_frameRateTimer = new QTimer(this);
	m_frameRateTimer->setSingleShot(true);
	m_frameRateTimer->setTimerType(Qt::PreciseTimer);
	connect(m_frameRateTimer, &QTimer::timeout, this, &VideoEncoder::processIncomingFrame);

	m_keyFrameTimer = new QTimer(this);
	m_keyFrameTimer->setSingleShot(true);
	connect(m_keyFrameTimer, &QTimer::timeout, this, &VideoEncoder::forceKeyFrame);
}

VideoEncoder::~VideoEncoder() = default;

void VideoEncoder::start(const QElapsedTimer &streamClock) {
	QMetaObject::invokeMethod(
		this, [this, streamClock]() { processStart(streamClock); }, Qt::QueuedConnection);
}

void VideoEncoder::stop() {
	QMetaObject::invokeMethod(
		this, [this]() { processStop(); }, Qt::QueuedConnection);
}

void VideoEncoder::submitFrame(const QImage &image, qint64 captureTime) {
	bool wakeUp;
	{
		QMutexLocker lock(&m_incomingMutex);
		// Replaces a frame that is still waiting to be encoded
		wakeUp                = m_incomingFrame.isNull();
		m_incomingFrame       = image;
		m_incomingCaptureTime = captureTime;
	}

	if (wakeUp)
		QMetaObject::invokeMethod(
			this, [this]() { processIncomingFrame(); }, Qt::QueuedConnection);
}

void VideoEncoder::requestKeyFrame() {
	QMetaObject::invokeMethod(
		this, [this]() { processKeyFrameRequest(); }, Qt::QueuedConnection);
}

void VideoEncoder::setSelection(const VideoEncoderSelection &selection) {
	QMetaObject::invokeMethod(
		this, [this, selection]() { processSelection(selection); }, Qt::QueuedConnection);
}

void VideoEncoder::setBitrate(int bitrate) {
	QMetaObject::invokeMethod(
		this, [this, bitrate]() { processBitrate(bitrate); }, Qt::QueuedConnection);
}

int VideoEncoder::bitrateFor(unsigned int maxBandwidth) {
	if (maxBandwidth == 0)
		return DEFAULT_BITRATE;

	// Leave room for the packet overhead and for the encoder overshooting its target for a moment, as the server
	// drops whatever exceeds the limit. Encoding at a very low bit rate isn't of any use either.
	static constexpr double HEADROOM = 0.8;
	static constexpr int MIN_BITRATE = 50'000;
	return static_cast< int >(std::clamp(maxBandwidth * HEADROOM, static_cast< double >(MIN_BITRATE),
										 static_cast< double >(DEFAULT_BITRATE)));
}

qint64 VideoEncoder::now() const {
	return m_streamClock.nsecsElapsed() / 1000;
}

void VideoEncoder::processStart(const QElapsedTimer &streamClock) {
	m_running        = true;
	m_streamClock    = streamClock;
	m_frameNumber    = 0;
	m_lastPts        = -1;
	m_lastEncodeTime = -1;
	m_lastFrame      = QImage();
}

void VideoEncoder::processStop() {
	m_running = false;
	m_frameRateTimer->stop();
	m_keyFrameTimer->stop();
	m_keyFrameRequested = false;
	m_lastFrame         = QImage();
	{
		QMutexLocker lock(&m_incomingMutex);
		m_incomingFrame = QImage();
	}
	m_backend.reset();
	m_encoderWidth  = 0;
	m_encoderHeight = 0;
	m_lastEncoderId.clear();
}

void VideoEncoder::processSelection(const VideoEncoderSelection &selection) {
	// Waits for the encoders to be probed, which is why this has to happen on the encoder's thread
	QStringList order = VideoEncoders::order(VideoEncoders::available(), selection);
	if (order == m_encoderOrder)
		return;
	m_encoderOrder = std::move(order);

	if (!m_backend || m_encoderOrder.isEmpty() || m_backend->info().id == m_encoderOrder.front())
		return;

	// Switch over to the now preferred encoder with the next frame. Viewers need a key frame for the new codec
	// right away, even if the screen content doesn't change.
	m_backend.reset();
	m_encoderWidth  = 0;
	m_encoderHeight = 0;
	forceKeyFrame();
}

void VideoEncoder::processBitrate(int bitrate) {
	if (bitrate == m_bitrate)
		return;
	m_bitrate = bitrate;

	if (!m_backend)
		return;

	// Encoders can't generally change their bit rate on the fly, so open the encoder again with the next frame
	m_backend.reset();
	m_encoderWidth  = 0;
	m_encoderHeight = 0;
	forceKeyFrame();
}

void VideoEncoder::processKeyFrameRequest() {
	if (!m_running || m_keyFrameRequested || m_keyFrameTimer->isActive())
		return;

	const qint64 currentTime = now();
	const qint64 earliest    = m_lastKeyFrameTime + MIN_KEYFRAME_REQUEST_INTERVAL_US;
	if (m_lastKeyFrameTime >= 0 && currentTime < earliest) {
		m_keyFrameTimer->start(static_cast< int >((earliest - currentTime + 999) / 1000));
		return;
	}

	forceKeyFrame();
}

void VideoEncoder::forceKeyFrame() {
	if (!m_running)
		return;

	m_keyFrameRequested = true;

	// Native capture streams only deliver a frame when the screen content changes, so the key frame might not
	// go out for a long time. Encode the last frame again in that case.
	if (m_lastFrame.isNull())
		return;

	bool idle;
	{
		QMutexLocker lock(&m_incomingMutex);
		idle = m_incomingFrame.isNull();
	}
	if (idle)
		submitFrame(m_lastFrame, now());
}

void VideoEncoder::processIncomingFrame() {
	if (!m_running)
		return;

	const qint64 currentTime = now();
	const qint64 nextSlot    = m_lastEncodeTime + FRAME_INTERVAL_US;
	if (m_lastEncodeTime >= 0 && currentTime < nextSlot) {
		// Make sure that the latest frame still goes out even if the source does not deliver another one
		// (which happens as soon as the screen content stops changing).
		if (!m_frameRateTimer->isActive())
			m_frameRateTimer->start(static_cast< int >((nextSlot - currentTime + 999) / 1000));
		return;
	}

	QImage frame;
	qint64 captureTime;
	{
		QMutexLocker lock(&m_incomingMutex);
		frame           = std::move(m_incomingFrame);
		m_incomingFrame = QImage();
		captureTime     = m_incomingCaptureTime;
	}
	if (frame.isNull())
		return;

	m_frameRateTimer->stop();
	m_lastFrame      = frame;
	m_lastEncodeTime = currentTime;

	encodeImage(frame, captureTime);
}

void VideoEncoder::encodeImage(const QImage &srcImage, qint64 captureTime) {
	// Encoders generally require even dimensions — crop one pixel if needed.
	const int width  = srcImage.width() & ~1;
	const int height = srcImage.height() & ~1;
	if (width <= 0 || height <= 0)
		return;
	const QImage image =
		(width != srcImage.width() || height != srcImage.height()) ? srcImage.copy(0, 0, width, height) : srcImage;

	// (Re-)open the encoder when the resolution changes. If no encoder works for a resolution, this is only
	// tried again once the resolution changes.
	if (m_encoderWidth != width || m_encoderHeight != height)
		openBackend(width, height);
	if (!m_backend)
		return;

	// The encoder runs on a microsecond time base, so the capture time can be used as pts directly. This lets
	// rate control see the real frame spacing, independently of the codec and of how regularly frames arrive.
	// Encoders reject non-increasing pts, which could only happen for two frames within the same microsecond.
	m_lastPts = std::max(captureTime, m_lastPts + 1);

	std::vector< VideoEncoderBackend::Packet > packets;
	if (!m_backend->encode(image, m_lastPts, m_keyFrameRequested, packets))
		return;

	m_keyFrameRequested = false;

	// Encoders may delay, reorder or drop frames, so all metadata is taken from the packets that come out.
	for (VideoEncoderBackend::Packet &packet : packets) {
		EncodedVideoFrame encoded;
		encoded.data        = std::move(packet.data);
		encoded.codec       = m_backend->info().codec;
		encoded.frameNumber = m_frameNumber++;
		encoded.timestamp   = static_cast< quint64 >(packet.timestamp);
		encoded.width       = static_cast< quint32 >(m_encoderWidth);
		encoded.height      = static_cast< quint32 >(m_encoderHeight);
		encoded.isKeyFrame  = packet.isKeyFrame;

		if (encoded.isKeyFrame) {
			// Also serves any request that is currently being held back
			m_lastKeyFrameTime = now();
			m_keyFrameTimer->stop();
		}

		emit frameEncoded(encoded);
	}
}

bool VideoEncoder::openBackend(int width, int height) {
	m_backend.reset();
	m_encoderWidth  = width;
	m_encoderHeight = height;

	VideoEncoderConfig config;
	config.width            = width;
	config.height           = height;
	config.bitrate          = m_bitrate;
	config.fps              = FPS;
	config.keyFrameInterval = VIDEO_GOP_SIZE;

	if (m_encoderOrder.isEmpty())
		m_encoderOrder = VideoEncoders::order(VideoEncoders::available(), VideoEncoderSelection());

	// The preferred encoder may not support every picture size (e.g. hardware encoders have size limits), so
	// fall back to the next one in that case.
	for (const QString &id : m_encoderOrder) {
		m_backend = VideoEncoders::create(id, config);
		if (m_backend)
			break;
	}

	if (!m_backend) {
		Global::get().l->log(
			Log::Warning,
			QObject::tr("Screen sharing: No video encoder is available for %1x%2.").arg(width).arg(height));
		return false;
	}

	if (m_backend->info().id != m_lastEncoderId) {
		m_lastEncoderId = m_backend->info().id;
		Global::get().l->log(Log::Information,
							 QObject::tr("Screen sharing: Encoding with %1.").arg(m_backend->info().name));
	}

	// A new encoder starts with a key frame anyway.
	m_keyFrameRequested = false;
	m_lastKeyFrameTime  = -1;
	m_keyFrameTimer->stop();
	return true;
}
