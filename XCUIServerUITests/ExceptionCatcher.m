#import "ExceptionCatcher.h"
NSException * _Nullable XSRunCatchingNSException(void (^block)(void)) {
    @try { block(); return nil; }
    @catch (NSException *e) { return e; }
    @catch (...) { return [NSException exceptionWithName:@"NonObjCThrow" reason:@"unknown throw" userInfo:nil]; }
}
