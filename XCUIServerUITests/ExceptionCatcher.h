#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs `block` and returns any NSException it raised (Swift can't catch these), or nil.
NSException * _Nullable XSRunCatchingNSException(void (^block)(void));
NS_ASSUME_NONNULL_END
