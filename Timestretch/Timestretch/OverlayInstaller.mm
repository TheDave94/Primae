// OverlayInstaller.mm
// Walks UIApplication.sharedApplication.windows to find the SDL view,
// then calls drawing_overlay_install() and touch_visualizer_install() on it.
// ⚠️  touch_visualizer_install is TEMPORARY — remove before App Store submission.

#import "OverlayInstaller.h"
#import "DrawingOverlay.h"
#import "TouchVisualizer.h"
#import <UIKit/UIKit.h>

void overlay_installer_attach(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* sdlWindow = nil;

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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            sdlWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
        }

        if (!sdlWindow) {
            NSLog(@"DrawingOverlay: could not find SDL UIWindow");
            return;
        }

        UIView* sdlView = sdlWindow.rootViewController
            ? sdlWindow.rootViewController.view
            : sdlWindow;

        drawing_overlay_install(sdlView);
        NSLog(@"DrawingOverlay: installed on %@", sdlView);

        // ⚠️  TEMPORARY: touch visualizer for screen recording demos
        touch_visualizer_install(sdlView);
    });
}
