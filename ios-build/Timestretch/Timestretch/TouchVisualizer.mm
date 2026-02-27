// TouchVisualizer.mm
// ⚠️  TEMPORARY — for screen recording demos only.
// Remove TouchVisualizer.h/.mm and the touch_visualizer_install() call
// in main.mm before App Store submission.
//
// Renders a semi-transparent circle under every active touch.
// Uses a passthrough UIGestureRecognizer so SDL still receives all events.

#import "TouchVisualizer.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// Passthrough recognizer — tracks touches without consuming them
// ---------------------------------------------------------------------------
@interface PassthroughGestureRecognizer : UIGestureRecognizer
@end

@implementation PassthroughGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesBegan:touches withEvent:event];
    self.state = UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesMoved:touches withEvent:event];
    self.state = UIGestureRecognizerStateChanged;
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesEnded:touches withEvent:event];
    self.state = UIGestureRecognizerStateEnded;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesCancelled:touches withEvent:event];
    self.state = UIGestureRecognizerStateCancelled;
}

// Critical: never fail, never cancel, never steal from SDL
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)other  { return NO; }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)other        { return NO; }
- (BOOL)shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer*)other { return NO; }

@end

// ---------------------------------------------------------------------------
// Touch dot view
// ---------------------------------------------------------------------------
static const CGFloat kDotDiameter  = 60.0f;   // visual circle diameter (pts)
static const CGFloat kDotAlpha     = 0.45f;   // opacity
static const UIColor* kDotColor(void) {
    return [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:kDotAlpha];
}

@interface TouchDotView : UIView
@end

@implementation TouchDotView
- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, kDotDiameter, kDotDiameter)];
    if (self) {
        self.backgroundColor        = kDotColor();
        self.layer.cornerRadius     = kDotDiameter / 2.0f;
        self.layer.masksToBounds    = YES;
        self.userInteractionEnabled = NO;
        // Thin ring border for contrast on white backgrounds
        self.layer.borderWidth      = 2.0f;
        self.layer.borderColor      = [UIColor colorWithWhite:0.0 alpha:0.25].CGColor;
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
// The overlay view that manages one dot per active touch
// ---------------------------------------------------------------------------
@interface TouchVisualizerView : UIView
@property (nonatomic, strong) NSMutableDictionary<NSValue*, TouchDotView*>* dotsByTouch;
@end

@implementation TouchVisualizerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor        = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.dotsByTouch            = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSValue*)keyFor:(UITouch*)touch { return [NSValue valueWithNonretainedObject:touch]; }

- (void)showTouches:(NSSet<UITouch*>*)touches {
    for (UITouch* touch in touches) {
        CGPoint loc = [touch locationInView:self];
        NSValue* key = [self keyFor:touch];
        TouchDotView* dot = self.dotsByTouch[key];
        if (!dot) {
            dot = [[TouchDotView alloc] init];
            [self addSubview:dot];
            self.dotsByTouch[key] = dot;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        dot.center = loc;
        [CATransaction commit];
    }
}

- (void)hideTouches:(NSSet<UITouch*>*)touches {
    for (UITouch* touch in touches) {
        NSValue* key = [self keyFor:touch];
        TouchDotView* dot = self.dotsByTouch[key];
        if (dot) {
            [dot removeFromSuperview];
            [self.dotsByTouch removeObjectForKey:key];
        }
    }
}

@end

// ---------------------------------------------------------------------------
// Glue: gesture recognizer → overlay
// ---------------------------------------------------------------------------
@interface TouchVisualizerCoordinator : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) TouchVisualizerView*          overlay;
@property (nonatomic, strong) PassthroughGestureRecognizer* recognizer;
@end

@implementation TouchVisualizerCoordinator

- (void)install:(UIView*)sdlView {
    _overlay = [[TouchVisualizerView alloc] initWithFrame:sdlView.bounds];
    [sdlView addSubview:_overlay];

    _recognizer = [[PassthroughGestureRecognizer alloc] initWithTarget:self action:@selector(handleGesture:)];
    _recognizer.delegate              = self;
    _recognizer.cancelsTouchesInView  = NO;
    _recognizer.delaysTouchesBegan    = NO;
    _recognizer.delaysTouchesEnded    = NO;
    [sdlView addGestureRecognizer:_recognizer];
}

- (void)handleGesture:(UIGestureRecognizer*)gr {
    // Dots are updated in the touch callbacks directly
}

// Forward all touch events from the gesture recognizer to the overlay
- (void)gestureRecognizer:(UIGestureRecognizer*)gr
     didReceiveTouches:(NSSet<UITouch*>*)touches {
    // Not a delegate method — use the UIGestureRecognizer override instead
}

// Use touchesBegan/Moved/Ended on the recognizer to drive the overlay
// by swizzling through a wrapper — simpler to use an actual UIView for tracking:
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gr
       shouldReceiveTouch:(UITouch*)touch {
    return YES;  // observe everything, steal nothing
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;  // never block SDL or other recognizers
}

- (void)remove {
    [_overlay removeFromSuperview];
    [_recognizer.view removeGestureRecognizer:_recognizer];
    _overlay     = nil;
    _recognizer  = nil;
}

@end

// The recognizer's action fires on state changes, but we need per-touch tracking.
// Easiest reliable approach: a transparent sibling UIView that gets touch events
// forwarded via hitTest, but since SDL needs them too, the cleanest solution on
// iOS is a UIWindow subclass or tracking via UIEvent in a custom UIApplication.
//
// For simplicity: subclass the recognizer to call our overlay directly.
@interface TrackingRecognizer : UIGestureRecognizer
@property (nonatomic, weak) TouchVisualizerView* overlay;
@end

@implementation TrackingRecognizer

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesBegan:touches withEvent:event];
    [self.overlay showTouches:touches];
    self.state = UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesMoved:touches withEvent:event];
    [self.overlay showTouches:touches];
    self.state = UIGestureRecognizerStateChanged;
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesEnded:touches withEvent:event];
    [self.overlay hideTouches:touches];
    self.state = UIGestureRecognizerStateEnded;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesCancelled:touches withEvent:event];
    [self.overlay hideTouches:touches];
    self.state = UIGestureRecognizerStateCancelled;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)o        { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)o  { return NO; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gr
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

@end

// ---------------------------------------------------------------------------
// C bridge
// ---------------------------------------------------------------------------
static TouchVisualizerView*    gTVOverlay     = nil;
static TrackingRecognizer*     gTVRecognizer  = nil;

void touch_visualizer_install(UIView* sdlView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Overlay
        gTVOverlay = [[TouchVisualizerView alloc] initWithFrame:sdlView.bounds];
        gTVOverlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sdlView addSubview:gTVOverlay];

        // Tracking recognizer
        gTVRecognizer          = [[TrackingRecognizer alloc] initWithTarget:nil action:nil];
        gTVRecognizer.overlay  = gTVOverlay;
        gTVRecognizer.cancelsTouchesInView  = NO;
        gTVRecognizer.delaysTouchesBegan    = NO;
        gTVRecognizer.delaysTouchesEnded    = NO;

        // Make it simultaneously compatible with everything
        // (delegate set on the recognizer itself via the category above)
        [sdlView addGestureRecognizer:gTVRecognizer];

        NSLog(@"[TouchVisualizer] Installed — REMOVE BEFORE APP STORE SUBMISSION");
    });
}

void touch_visualizer_remove(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTVRecognizer) {
            [gTVRecognizer.view removeGestureRecognizer:gTVRecognizer];
            gTVRecognizer = nil;
        }
        if (gTVOverlay) {
            [gTVOverlay removeFromSuperview];
            gTVOverlay = nil;
        }
    });
}
