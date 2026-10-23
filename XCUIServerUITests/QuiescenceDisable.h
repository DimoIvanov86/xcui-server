#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Turns off XCTest's wait for the app to go idle before each event, as WebDriverAgent does.
/// An app that never stops animating would otherwise stall every tap. Uses private API.
/// Returns a status string for the log.
NSString *XSDisableQuiescenceWait(void);
NS_ASSUME_NONNULL_END
