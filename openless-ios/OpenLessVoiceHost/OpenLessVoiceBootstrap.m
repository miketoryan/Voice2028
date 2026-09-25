#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static void OpenLessStartVoiceRuntime(void) {
    Class cls = NSClassFromString(@"OpenLessVoiceRuntime");
    SEL selector = NSSelectorFromString(@"startShared");
    if (cls && [cls respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(cls, selector);
    }
}

__attribute__((constructor))
static void OpenLessVoiceBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        OpenLessStartVoiceRuntime();
    });
}
