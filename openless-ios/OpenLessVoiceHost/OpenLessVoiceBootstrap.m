#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern void openless_chatgpt_begin_login(void);
// Rust resolves this symbol with dlsym at runtime. Keep an Objective-C reference
// so the app linker cannot dead-strip the Swift @_cdecl entry point.
__attribute__((used))
static void (*const OpenLessKeepChatGPTLoginSymbol)(void) = openless_chatgpt_begin_login;

__attribute__((constructor))
static void OpenLessVoiceBootstrapConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"OpenLessVoiceBootstrap");
        if (!cls) return;

        id shared = nil;
        SEL sharedSelector = NSSelectorFromString(@"shared");
        if ([cls respondsToSelector:sharedSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            shared = [cls performSelector:sharedSelector];
#pragma clang diagnostic pop
        }

        SEL startSelector = NSSelectorFromString(@"start");
        if (shared && [shared respondsToSelector:startSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [shared performSelector:startSelector];
#pragma clang diagnostic pop
        }
    });
}
