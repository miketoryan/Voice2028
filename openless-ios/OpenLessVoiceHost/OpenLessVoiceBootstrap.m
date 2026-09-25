#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdbool.h>

static id OpenLessVoiceBootstrapShared(void) {
    Class cls = NSClassFromString(@"OpenLessVoiceBootstrap");
    if (!cls) return nil;

    SEL sharedSelector = NSSelectorFromString(@"shared");
    if (![cls respondsToSelector:sharedSelector]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [cls performSelector:sharedSelector];
#pragma clang diagnostic pop
}

bool OpenLessNativeAudioStart(void) {
    __block bool started = false;
    void (^work)(void) = ^{
        id shared = OpenLessVoiceBootstrapShared();
        SEL selector = NSSelectorFromString(@"startNativeAudioCapture");
        if (!shared || ![shared respondsToSelector:selector]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSNumber *result = [shared performSelector:selector];
#pragma clang diagnostic pop
        started = result.boolValue;
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return started;
}

void OpenLessNativeAudioStop(void) {
    void (^work)(void) = ^{
        id shared = OpenLessVoiceBootstrapShared();
        SEL selector = NSSelectorFromString(@"stopNativeAudioCapture");
        if (!shared || ![shared respondsToSelector:selector]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [shared performSelector:selector];
#pragma clang diagnostic pop
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

__attribute__((constructor))
static void OpenLessVoiceBootstrapConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id shared = OpenLessVoiceBootstrapShared();

        SEL startSelector = NSSelectorFromString(@"start");
        if (shared && [shared respondsToSelector:startSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [shared performSelector:startSelector];
#pragma clang diagnostic pop
        }
    });
}
