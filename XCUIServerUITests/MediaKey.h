#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends a hardware HID event (e.g. Play/Pause: page 0x0C, usage 0xCD) through XCTest's private
/// XCDeviceEvent. Returns nil on success, otherwise the reason it failed.
NSString *_Nullable XSPerformHIDEvent(unsigned int page, unsigned int usage, double duration);

NS_ASSUME_NONNULL_END
