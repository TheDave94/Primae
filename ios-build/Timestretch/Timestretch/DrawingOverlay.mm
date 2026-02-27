// DrawingOverlay.mm
// UIView overlay that draws the green tracing feedback using CAShapeLayer.
// One CAShapeLayer per stroke — each layer lives in UIKit points, which are
// automatically scaled by Core Animation for Retina without any manual maths.
// Smooth path: uses midpoint quadratic Bézier curves to eliminate bumps.

#import "DrawingOverlay.h"
#import <QuartzCore/QuartzCore.h>

static const int kMaxStrokes = 8;

// ---------------------------------------------------------------------------
// DrawingOverlayView
// ---------------------------------------------------------------------------
@interface DrawingOverlayView : UIView
@property (nonatomic, strong) NSMutableArray<CAShapeLayer*>*           strokeLayers;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSValue*>*>* strokePoints;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*               strokeStarted;
- (void)setupLayers;
- (void)beginStroke:(int)idx;
- (void)addPoint:(CGPoint)pt toStroke:(int)idx;
- (void)completeStroke:(int)idx;
- (void)resetStroke:(int)idx;
- (void)resetAll;
- (CGPathRef)smoothPathForPoints:(NSArray<NSValue*>*)pts CF_RETURNS_RETAINED;
@end

@implementation DrawingOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor        = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self setupLayers];
    }
    return self;
}

- (void)setupLayers {
    _strokeLayers  = [NSMutableArray array];
    _strokePoints  = [NSMutableArray array];
    _strokeStarted = [NSMutableArray array];

    for (int i = 0; i < kMaxStrokes; ++i) {
        CAShapeLayer* layer = [CAShapeLayer layer];
        layer.fillColor     = [UIColor clearColor].CGColor;
        layer.strokeColor   = [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:0.9].CGColor;
        layer.lineWidth     = 44.0;   // ~44pt brush width on iPad
        layer.lineCap       = kCALineCapRound;
        layer.lineJoin      = kCALineJoinRound;
        layer.hidden        = YES;
        [self.layer addSublayer:layer];
        [_strokeLayers  addObject:layer];
        [_strokePoints  addObject:[NSMutableArray array]];
        [_strokeStarted addObject:@NO];
    }
}

- (CGPoint)denorm:(float)nx y:(float)ny {
    return CGPointMake(nx * self.bounds.size.width,
                       ny * self.bounds.size.height);
}

// Midpoint quadratic Bézier smoothing — eliminates the bumpy segment look.
// With 1 point: just a dot (moveToPoint only, no line).
// With 2 points: straight line.
// With 3+: smooth curve through midpoints with quadratic curves.
- (CGPathRef)smoothPathForPoints:(NSArray<NSValue*>*)pts CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    NSUInteger n = pts.count;
    if (n == 0) return path;

    CGPoint p0 = [pts[0] CGPointValue];
    CGPathMoveToPoint(path, nil, p0.x, p0.y);

    if (n == 1) return path;
    if (n == 2) {
        CGPoint p1 = [pts[1] CGPointValue];
        CGPathAddLineToPoint(path, nil, p1.x, p1.y);
        return path;
    }

    for (NSUInteger i = 0; i < n - 1; ++i) {
        CGPoint curr = [pts[i]     CGPointValue];
        CGPoint next = [pts[i + 1] CGPointValue];
        CGPoint mid  = CGPointMake((curr.x + next.x) * 0.5f,
                                   (curr.y + next.y) * 0.5f);
        CGPathAddQuadCurveToPoint(path, nil, curr.x, curr.y, mid.x, mid.y);
    }
    // Final segment to last point
    CGPoint last = [pts[n-1] CGPointValue];
    CGPathAddLineToPoint(path, nil, last.x, last.y);
    return path;
}

- (void)updateLayer:(int)idx {
    NSArray<NSValue*>* pts = _strokePoints[(NSUInteger)idx];
    CGPathRef smooth = [self smoothPathForPoints:pts];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path = smooth;
    [CATransaction commit];
    CGPathRelease(smooth);
}

- (void)beginStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    CAShapeLayer* layer = _strokeLayers[(NSUInteger)idx];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.path   = nil;
    layer.hidden = NO;
    // In-progress: slightly lighter green
    layer.strokeColor = [UIColor colorWithRed:0.39 green:0.90 blue:0.47 alpha:0.85].CGColor;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @YES;
}

- (void)addPoint:(CGPoint)pt toStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    if (![_strokeStarted[(NSUInteger)idx] boolValue]) return;
    // Deduplicate: skip if too close to last point (< 8pt = smoother path, fewer segments)
    NSMutableArray<NSValue*>* pts = _strokePoints[(NSUInteger)idx];
    if (pts.count > 0) {
        CGPoint last = [pts.lastObject CGPointValue];
        CGFloat d = hypot(pt.x - last.x, pt.y - last.y);
        if (d < 8.0) return;
    }
    [pts addObject:[NSValue valueWithCGPoint:pt]];
    [self updateLayer:idx];
}

- (void)completeStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Solid completed green
    _strokeLayers[(NSUInteger)idx].strokeColor =
        [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:1.0].CGColor;
    _strokeLayers[(NSUInteger)idx].hidden = NO;
    [CATransaction commit];
}

- (void)resetStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path   = nil;
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
        if (gOverlay) { [gOverlay removeFromSuperview]; gOverlay = nil; }
        gOverlay = [[DrawingOverlayView alloc] initWithFrame:sdlView.bounds];
        gOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sdlView addSubview:gOverlay];
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
        if (!gOverlay) return;
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
