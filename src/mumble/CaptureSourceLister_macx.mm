// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifdef USE_SCREEN_SHARING

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "CaptureSourceLister.h"

#include <QtGui/QGuiApplication>
#include <QtGui/QImage>
#include <QtGui/QPixmap>
#include <QtGui/QScreen>

#include <memory>

static constexpr int THUMBNAIL_WIDTH = 160;
static constexpr int THUMBNAIL_HEIGHT = 90;

/// Upper bound for waiting on ScreenCaptureKit, so that a request that never
/// completes cannot freeze the GUI thread.
static constexpr int64_t SCREENCAPTUREKIT_TIMEOUT_NS = 2 * NSEC_PER_SEC;

// CGWindowListCreateImage is unavailable as of macOS 15, so windows are
// captured through ScreenCaptureKit. Its API is asynchronous while the
// functions in this file are synchronous, so the helpers below wait for the
// completion handler. The result is stored in a heap object shared with the
// handler: if the wait times out, the handler may still run later and the
// object then releases whatever it delivered.

/// Owns the result of an asynchronous ScreenCaptureKit request.
struct ShareableContentResult {
  SCShareableContent *content = nil;
  ~ShareableContentResult() { [content release]; }
};

struct ImageResult {
  CGImageRef image = nullptr;
  ~ImageResult() {
    if (image)
      CGImageRelease(image);
  }
};

/// Fetches the on-screen windows and displays. The returned object is owned
/// by the caller (release it), or nil on failure.
static SCShareableContent *copyShareableContent() {
  std::shared_ptr<ShareableContentResult> result =
      std::make_shared<ShareableContentResult>();
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  [SCShareableContent
      getShareableContentExcludingDesktopWindows:YES
                             onScreenWindowsOnly:YES
                               completionHandler:^(SCShareableContent *content,
                                                   NSError *error) {
                                 (void)error;
                                 result->content = [content retain];
                                 dispatch_semaphore_signal(done);
                               }];

  const bool finished =
      dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW,
                              SCREENCAPTUREKIT_TIMEOUT_NS)) == 0;
  dispatch_release(done);
  if (!finished)
    return nil;

  SCShareableContent *content = result->content;
  result->content = nil;
  return content;
}

/// Looks up the SCWindow with the given CGWindowID in the shareable content.
static SCWindow *findWindow(SCShareableContent *content, CGWindowID windowId) {
  for (SCWindow *window in content.windows) {
    if (window.windowID == windowId)
      return window;
  }
  return nil;
}

/// Captures a single window at its native resolution. The returned image is
/// owned by the caller (CGImageRelease), or nullptr on failure.
static CGImageRef copyWindowImage(SCWindow *window) {
  if (!window)
    return nullptr;

  SCContentFilter *filter =
      [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  const CGFloat scale = filter.pointPixelScale;
  config.width = static_cast<size_t>(filter.contentRect.size.width * scale);
  config.height = static_cast<size_t>(filter.contentRect.size.height * scale);
  config.showsCursor = NO;

  std::shared_ptr<ImageResult> result = std::make_shared<ImageResult>();
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  [SCScreenshotManager
      captureImageWithFilter:filter
               configuration:config
           completionHandler:^(CGImageRef image, NSError *error) {
             (void)error;
             if (image)
               result->image = CGImageRetain(image);
             dispatch_semaphore_signal(done);
           }];

  const bool finished =
      dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW,
                              SCREENCAPTUREKIT_TIMEOUT_NS)) == 0;
  dispatch_release(done);
  [config release];
  [filter release];
  if (!finished)
    return nullptr;

  CGImageRef image = result->image;
  result->image = nullptr;
  return image;
}

/// Convert a CoreGraphics image to a QImage using a CGBitmapContext.
/// The result uses Format_ARGB32_Premultiplied (BGRA / premultiplied alpha).
static QImage qImageFromCGImage(CGImageRef cgImage) {
  if (!cgImage)
    return {};

  const size_t width = CGImageGetWidth(cgImage);
  const size_t height = CGImageGetHeight(cgImage);

  QImage image(static_cast<int>(width), static_cast<int>(height),
               QImage::Format_ARGB32_Premultiplied);
  image.fill(Qt::transparent);

  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(
      image.bits(), width, height,
      8, // bits per component
      static_cast<size_t>(image.bytesPerLine()), colorSpace,
      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
  CGColorSpaceRelease(colorSpace);
  if (!ctx)
    return {};

  CGContextDrawImage(ctx,
                     CGRectMake(0, 0, static_cast<CGFloat>(width),
                                static_cast<CGFloat>(height)),
                     cgImage);
  CGContextRelease(ctx);
  return image;
}

static QPixmap pixmapFromCGImage(CGImageRef cgImage) {
  if (!cgImage)
    return {};
  QImage img = qImageFromCGImage(cgImage);
  if (img.isNull())
    return {};
  return QPixmap::fromImage(img.scaled(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT,
                                       Qt::KeepAspectRatio,
                                       Qt::SmoothTransformation));
}

static QString cfStringToQString(CFStringRef str) {
  if (!str)
    return {};
  // Fast path: ASCII/UTF-8 buffer
  const char *cStr = CFStringGetCStringPtr(str, kCFStringEncodingUTF8);
  if (cStr)
    return QString::fromUtf8(cStr);
  // Slow path: allocate
  CFIndex length = CFStringGetLength(str);
  QByteArray buf(static_cast<int>(length * 4 + 1), '\0');
  if (CFStringGetCString(str, buf.data(), buf.size(), kCFStringEncodingUTF8))
    return QString::fromUtf8(buf.constData());
  return {};
}

QList<CaptureSource> listCaptureSources() {
  QList<CaptureSource> sources;

  // --- Screens ---
  const QList<QScreen *> screens = QGuiApplication::screens();
  for (int i = 0; i < screens.size(); ++i) {
    QScreen *screen = screens.at(i);
    CaptureSource s;
    s.type = CaptureSource::Type::EntireScreen;
    s.screenIndex = i;
    s.displayName = QObject::tr("Display %1 (%2×%3)")
                        .arg(i + 1)
                        .arg(screen->size().width())
                        .arg(screen->size().height());

    // Grab thumbnail using Qt — works for screens on macOS at picker time.
    QPixmap px = screen->grabWindow(0);
    if (!px.isNull()) {
      s.thumbnail = QPixmap::fromImage(
          px.toImage().scaled(THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT,
                              Qt::KeepAspectRatio, Qt::SmoothTransformation));
    }
    sources.append(s);
  }

  // --- Windows (CoreGraphics) ---
  CFArrayRef windowList = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  if (!windowList)
    return sources;

  // Used for the window thumbnails
  SCShareableContent *shareableContent = copyShareableContent();

  CFIndex count = CFArrayGetCount(windowList);
  for (CFIndex i = 0; i < count; ++i) {
    auto *info =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(windowList, i));
    if (!info)
      continue;

    // Only include normal application windows (layer 0).
    auto *layerRef =
        static_cast<CFNumberRef>(CFDictionaryGetValue(info, kCGWindowLayer));
    if (!layerRef)
      continue;
    int layer = 0;
    CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
    if (layer != 0)
      continue;

    // Skip Window Server (system compositor) entries.
    auto *ownerNameRef = static_cast<CFStringRef>(
        CFDictionaryGetValue(info, kCGWindowOwnerName));
    const QString ownerName = cfStringToQString(ownerNameRef);
    if (ownerName == QLatin1String("Window Server"))
      continue;

    // Window ID.
    auto *windowNumRef =
        static_cast<CFNumberRef>(CFDictionaryGetValue(info, kCGWindowNumber));
    if (!windowNumRef)
      continue;
    uint32_t windowId = 0;
    CFNumberGetValue(windowNumRef, kCFNumberSInt32Type, &windowId);

    // Window name (may be empty for some apps).
    auto *windowNameRef =
        static_cast<CFStringRef>(CFDictionaryGetValue(info, kCGWindowName));
    const QString windowName = cfStringToQString(windowNameRef);

    // Display name: "AppName - WindowTitle" or just "AppName".
    QString displayName = ownerName;
    if (!windowName.isEmpty() && windowName != ownerName)
      displayName += QLatin1String(" - ") + windowName;

    // Thumbnail via ScreenCaptureKit window capture.
    CGImageRef cgImg = copyWindowImage(
        findWindow(shareableContent, static_cast<CGWindowID>(windowId)));
    QPixmap thumbnail = pixmapFromCGImage(cgImg);
    if (cgImg)
      CGImageRelease(cgImg);

    CaptureSource s;
    s.type = CaptureSource::Type::Window;
    s.nativeWindowId = static_cast<quintptr>(windowId);
    s.displayName = displayName;
    s.thumbnail = thumbnail;
    sources.append(s);
  }

  [shareableContent release];
  CFRelease(windowList);
  return sources;
}

QImage grabCaptureSource(const CaptureSource &source) {
  if (source.type == CaptureSource::Type::EntireScreen) {
    const QList<QScreen *> screens = QGuiApplication::screens();
    if (source.screenIndex < 0 || source.screenIndex >= screens.size())
      return {};
    QPixmap px = screens.at(source.screenIndex)->grabWindow(0);
    if (px.isNull())
      return {};
    return px.toImage().convertToFormat(QImage::Format_RGBA8888);
  }

  // Window capture — must use ScreenCaptureKit on macOS.
  // Qt's QScreen::grabWindow(WId) does NOT capture specific windows on macOS
  // because WId is an NSView pointer, not a CGWindowID.
  SCShareableContent *shareableContent = copyShareableContent();
  CGImageRef cgImage = copyWindowImage(findWindow(
      shareableContent, static_cast<CGWindowID>(source.nativeWindowId)));
  [shareableContent release];
  if (!cgImage)
    return {};

  QImage img = qImageFromCGImage(cgImage);
  CGImageRelease(cgImage);
  return img.convertToFormat(QImage::Format_RGBA8888);
}

#endif // USE_SCREEN_SHARING
