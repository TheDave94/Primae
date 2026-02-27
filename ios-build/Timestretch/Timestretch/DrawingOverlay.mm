// DrawingOverlay.mm
// UIView overlay that draws the green tracing feedback using CAShapeLayer.
// One CAShapeLayer per stroke — each layer lives in UIKit points, which are
// automatically scaled by Core Animation for Retina without any manual maths.

#import "DrawingOverlay.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// Maximum number of strokes any letter has (M has 4)
// ---------------------------------------------------------------------------
static const int kMaxStrokes = 8;

// ---------------------------------------------------------------------------
// DrawingOverlayView
// ---------------------------------------------------------------------------
@interface DrawingOverlayView : UIView
@property (nonatomic, strong) NSMutableArray<CAShapeLayer*>* strokeLayers;
@property (nonatomic, strong) NSMutableArray<UIBezierPath*>*  strokePaths;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*      strokeStarted; // BOOL per stroke
- (void)setupLayers;
- (void)beginStroke:(int)idx;
- (void)addPoint:(CGPoint)pt toStroke:(int)idx;
- (void)completeStroke:(int)idx;
- (void)resetStroke:(int)idx;
- (void)resetAll;
@end

@implementation DrawingOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor   = [UIColor clearColor];
        self.userInteractionEnabled = NO; // touches pass through to SDL
        self.autoresizingMask  = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self setupLayers];
    }
    return self;
}

- (void)setupLayers {
    _strokeLayers  = [NSMutableArray array];
    _strokePaths   = [NSMutableArray array];
    _strokeStarted = [NSMutableArray array];

    for (int i = 0; i < kMaxStrokes; ++i) {
        UIBezierPath* path = [UIBezierPath bezierPath];
        path.lineWidth     = 0; // unused — we use fill via wide line cap trick below

        CAShapeLayer* layer   = [CAShapeLayer layer];
        layer.fillColor       = [UIColor clearColor].CGColor;
        layer.strokeColor     = [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:0.9].CGColor;
        layer.lineWidth       = 44.0; // ~44pt feels like a thick brush on iPad
        layer.lineCap         = kCALineCapRound;
        layer.lineJoin        = kCALineJoinRound;
        layer.path            = path.CGPath;
        layer.hidden          = YES;

        [self.layer addSublayer:layer];
        [_strokeLayers addObject:layer];
        [_strokePaths  addObject:path];
        [_strokeStarted addObject:@NO];
    }
}

- (CGPoint)denorm:(float)nx y:(float)ny {
    // Convert normalised [0,1] → UIKit points (self.bounds)
    return CGPointMake(nx * self.bounds.size.width,
                       ny * self.bounds.size.height);
}

- (void)beginStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    // Clear existing path
    UIBezierPath* path   = _strokePaths[(NSUInteger)idx];
    [path removeAllPoints];
    CAShapeLayer* layer  = _strokeLayers[(NSUInteger)idx];
    layer.path           = path.CGPath;
    // In-progress colour: slightly lighter
    layer.strokeColor    = [UIColor colorWithRed:0.39 green:0.90 blue:0.47 alpha:0.85].CGColor;
    layer.hidden         = NO;
    _strokeStarted[(NSUInteger)idx] = @YES;
}

- (void)addPoint:(CGPoint)pt toStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    if (![_strokeStarted[(NSUInteger)idx] boolValue]) return;

    UIBezierPath* path = _strokePaths[(NSUInteger)idx];
    if (path.isEmpty) {
        [path moveToPoint:pt];
    } else {
        [path addLineToPoint:pt];
    }
    // Update layer path without implicit animation (instant, no lag)
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path = path.CGPath;
    [CATransaction commit];
}

- (void)completeStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    // Switch to solid completed colour
    CAShapeLayer* layer  = _strokeLayers[(NSUInteger)idx];
    layer.strokeColor    = [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:1.0].CGColor;
    layer.hidden         = NO;
}

- (void)resetStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    UIBezierPath* path = _strokePaths[(NSUInteger)idx];
    [path removeAllPoints];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path   = path.CGPath;
    _strokeLayers[(NSUInteger)idx].hidden = YES;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @NO;
}

- (void)resetAll {
    for (int i = 0; i < kMaxStrokes; ++i) [self resetStroke:i];
}

@end

// ---------------------------------------------------------------------------
// Singleton + C bridge
// ---------------------------------------------------------------------------
static DrawingOverlayView* gOverlay = nil;

void drawing_overlay_install(UIView* sdlView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gOverlay) {
            [gOverlay removeFromSuperview];
            gOverlay = nil;
        }
        gOverlay = [[DrawingOverlayView alloc] initWithFrame:sdlView.bounds];
        [sdlView addSubview:gOverlay];
        // Keep overlay filling SDL view on rotation
        gOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    });
}

static void on_main(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

void drawing_overlay_begin_stroke(int idx) {
    on_main(^{ [gOverlay beginStroke:idx]; });
}

void drawing_overlay_add_point(int strokeIndex, float nx, float ny) {
    on_main(^{
        CGPoint pt = [gOverlay denorm:nx y:ny];
        [gOverlay addPoint:pt toStroke:strokeIndex];
    });
}

void drawing_overlay_complete_stroke(int idx) {
    on_main(^{ [gOverlay completeStroke:idx]; });
}

void drawing_overlay_reset_stroke(int idx) {
    on_main(^{ [gOverlay resetStroke:idx]; });
}

void drawing_overlay_reset_all(void) {
    on_main(^{ [gOverlay resetAll]; });
}
