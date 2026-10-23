#import "QuiescenceDisable.h"
#import <objc/runtime.h>

// What a patched method does instead. Each replacement must match the original method's signature.
typedef NS_ENUM(NSInteger, XSReplacement) {
    XSReturnYes,          // - (BOOL)selector
    XSReturnNo,           // - (BOOL)selector
    XSIgnoreBool,         // - (void)selector:(BOOL)
    XSIgnoreBoolBool,     // - (void)selector:(BOOL) x:(BOOL)
    XSIgnoreBoolObjBool,  // - (void)selector:(BOOL) x:(id) y:(BOOL)
};

static IMP implementationFor(XSReplacement replacement) {
    switch (replacement) {
        case XSReturnYes: return imp_implementationWithBlock(^BOOL(__unused id s) { return YES; });
        case XSReturnNo: return imp_implementationWithBlock(^BOOL(__unused id s) { return NO; });
        case XSIgnoreBool: return imp_implementationWithBlock(^(__unused id s, __unused BOOL a) {});
        case XSIgnoreBoolBool: return imp_implementationWithBlock(^(__unused id s, __unused BOOL a, __unused BOOL b) {});
        case XSIgnoreBoolObjBool:
            return imp_implementationWithBlock(^(__unused id s, __unused BOOL a, __unused id b, __unused BOOL c) {});
    }
}

NSString *XSDisableQuiescenceWait(void) {
    // _makeQuiescenceExpectation returns an object, so it is left alone.
    static const struct { const char *cls; const char *sel; XSReplacement replacement; } patches[] = {
        { "XCUIApplicationProcess", "shouldSkipPreEventQuiescence", XSReturnYes },
        { "XCUIApplicationProcess", "shouldSkipPostEventQuiescence", XSReturnYes },
        { "XCUIApplicationProcess", "isQuiescent", XSReturnYes },
        { "XCUIApplicationProcess", "_initiateQuiescenceChecksIncludingAnimationsIdle:", XSIgnoreBool },
        { "XCUIApplicationProcess", "waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", XSIgnoreBoolBool },
        { "XCUIApplicationProcess", "waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:", XSIgnoreBoolObjBool },
        { "XCUIApplication", "isIdleAnimationWaitEnabled", XSReturnNo },
    };
    NSMutableArray<NSString *> *done = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(patches) / sizeof(patches[0]); i++) {
        Class cls = NSClassFromString(@(patches[i].cls));
        if (cls == nil) {
            continue;
        }
        NSString *name = @(patches[i].sel);
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (method == NULL) {
            continue;
        }
        method_setImplementation(method, implementationFor(patches[i].replacement));
        [done addObject:name];
    }
    if (done.count == 0) { return @"no quiescence selector found (XCTest unchanged)"; }
    return [NSString stringWithFormat:@"quiescence disabled (%@)", [done componentsJoinedByString:@", "]];
}
