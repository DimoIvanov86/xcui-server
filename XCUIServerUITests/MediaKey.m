#import "MediaKey.h"
#import <XCTest/XCTest.h>

// Private XCTest API, declared here so the call compiles; its presence is checked at run time.
@interface XCUIDevice (XSDeviceEvent)
- (BOOL)performDeviceEvent:(id)event error:(NSError **)error;
@end

NSString *XSPerformHIDEvent(unsigned int page, unsigned int usage, double duration) {
    Class eventClass = NSClassFromString(@"XCDeviceEvent");
    SEL factory = NSSelectorFromString(@"deviceEventWithPage:usage:duration:");
    if (eventClass == nil || ![eventClass respondsToSelector:factory]) {
        return @"XCDeviceEvent deviceEventWithPage:usage:duration: not found";
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[eventClass methodSignatureForSelector:factory]];
    invocation.selector = factory;
    [invocation setArgument:&page atIndex:2];
    [invocation setArgument:&usage atIndex:3];
    [invocation setArgument:&duration atIndex:4];
    [invocation invokeWithTarget:eventClass];
    id __unsafe_unretained event = nil;
    [invocation getReturnValue:&event];
    if (event == nil) {
        return @"XCDeviceEvent factory returned nil";
    }
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(performDeviceEvent:error:)]) {
        return @"XCUIDevice performDeviceEvent:error: not found";
    }
    NSError *error = nil;
    if (![device performDeviceEvent:event error:&error]) {
        return error.localizedDescription ?: @"performDeviceEvent:error: failed";
    }
    return nil;
}
