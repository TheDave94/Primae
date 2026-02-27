// OverlayInstaller.mm
// Walks UIApplication.sharedApplication.windows to find the SDL view,
// then calls drawing_overlay_install() on it.

#import "OverlayInstaller.h"
#import "DrawingOverlay.h"
#import <UIKit/UIKit.h>

void overlay_installer_attach(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // SDL3 creates exactly one UIWindow; its rootViewController's view
        // (or the window itself) is what we want to sit on top of.
        UIWindow* sdlWindow = nil;

        // iOS 15+: use connectedScenes
        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* ws = (UIWindowScene*)scene;
                for (UIWindow* w in ws.windows) {
                    if (w.isKeyWindow || sdlWindow == nil) {
                        sdlWindow = w;
                    }
                }
            }
        }

        if (!sdlWindow) {
            // Fallback for older iOS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            sdlWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
        }

        if (!sdlWindow) {
            NSLog(@"DrawingOverlay: could not find SDL UIWindow");
            return;
        }

        // SDL's UIView is the first (and only) subview of the window.
        // If there's a rootViewController, use its view; otherwise use the window itself.
        UIView* sdlView = sdlWindow.rootViewController
            ? sdlWindow.rootViewController.view
            : sdlWindow;

        drawing_overlay_install(sdlView);
        NSLog(@"DrawingOverlay: installed on %@", sdlView);
    });
}
