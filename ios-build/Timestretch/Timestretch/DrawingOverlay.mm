// DrawingOverlay.mm
// UIView overlay for green stroke feedback.
// CAShapeLayer with kCALineCapButt — flush caps, zero protrusion, no bumps.
// Completed strokes are NEVER reset individually — only reset_all() clears them.
// When all strokes are done, show_mask() floods the entire letter shape green.

#import "DrawingOverlay.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static const int   kMaxStrokes   = 8;
static const float kBrushWidth   = 40.0f;
static const float kMinPointDist = 10.0f;

// ---------------------------------------------------------------------------
// PBM → green UIImage
// Reads P4 binary PBM, renders black pixels as solid green, white as clear.
// ---------------------------------------------------------------------------
static UIImage* greenImageFromPBM(NSString* path) {
    if (!path) return nil;

    FILE* f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;

    // Read header: magic, optional comments, width, height
    char magic[8] = {};
    if (!fgets(magic, sizeof(magic), f) || strncmp(magic, "P4", 2) != 0) { fclose(f); return nil; }

    int width = 0, height = 0;
    // Skip comment lines
    int ch;
    while ((ch = fgetc(f)) == '#') {
        while ((ch = fgetc(f)) != '\n' && ch != EOF) {}
    }
    ungetc(ch, f);
    if (fscanf(f, " %d %d", &width, &height) != 2 || width <= 0 || height <= 0) { fclose(f); return nil; }
    fgetc(f); // consume single whitespace separator before binary data

    int rowBytes = (width + 7) / 8;
    size_t dataSize = (size_t)(rowBytes * height);
    uint8_t* pbmBits = (uint8_t*)malloc(dataSize);
    if (!pbmBits) { fclose(f); return nil; }
    fread(pbmBits, 1, dataSize, f);
    fclose(f);

    // Build RGBA8 bitmap: black PBM pixel → green, white → transparent
    size_t rgbaSize = (size_t)(width * height * 4);
    uint8_t* rgba = (uint8_t*)calloc(rgbaSize, 1);
    if (!rgba) { free(pbmBits); return nil; }

    // Green with 90% opacity
    const uint8_t R = 61, G = 209, B = 79, A = 230;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            uint8_t byte = pbmBits[y * rowBytes + x / 8];
            int bit = (byte >> (7 - (x % 8))) & 1;
            if (bit) { // black pixel = letter shape
                size_t idx = (size_t)((y * width + x) * 4);
                rgba[idx + 0] = R;
                rgba[idx + 1] = G;
                rgba[idx + 2] = B;
                rgba[idx + 3] = A;
            }
            // white pixel stays transparent (calloc zeroed it)
        }
    }
    free(pbmBits);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, (size_t)width, (size_t)height,
                                             8, (size_t)(width * 4), cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(rgba); return nil; }

    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(rgba);
    if (!cgImg) return nil;

    UIImage* img = [UIImage imageWithCGImage:cgImg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImg);
    return img;
}

// ---------------------------------------------------------------------------
@interface DrawingOverlayView : UIView
@property (nonatomic, strong) NSMutableArray<CAShapeLayer*>*             strokeLayers;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSValue*>*>* strokePoints;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*                 strokeStarted;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*                 strokeComplete;
@property (nonatomic, strong) UIImageView*                               maskOverlay;
- (void)setupLayers;
- (void)beginStroke:(int)idx;
- (void)addPoint:(CGPoint)pt toStroke:(int)idx;
- (void)completeStroke:(int)idx;
- (void)resetStroke:(int)idx;
- (void)resetAll;
- (void)showMaskFromPBM:(NSString*)pbmPath;
- (void)hideMask;
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
    _strokeLayers   = [NSMutableArray array];
    _strokePoints   = [NSMutableArray array];
    _strokeStarted  = [NSMutableArray array];
    _strokeComplete = [NSMutableArray array];

    for (int i = 0; i < kMaxStrokes; ++i) {
        CAShapeLayer* layer = [CAShapeLayer layer];
        layer.fillColor     = [UIColor clearColor].CGColor;
        layer.strokeColor   = [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:0.9].CGColor;
        layer.lineWidth     = kBrushWidth;
        layer.lineCap       = kCALineCapButt;
        layer.lineJoin      = kCALineJoinRound;
        layer.hidden        = YES;
        [self.layer addSublayer:layer];
        [_strokeLayers   addObject:layer];
        [_strokePoints   addObject:[NSMutableArray array]];
        [_strokeStarted  addObject:@NO];
        [_strokeComplete addObject:@NO];
    }

    // Mask overlay sits on top of all stroke layers
    _maskOverlay                  = [[UIImageView alloc] initWithFrame:self.bounds];
    _maskOverlay.contentMode      = UIViewContentModeScaleToFill;
    _maskOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _maskOverlay.hidden           = YES;
    [self addSubview:_maskOverlay];
}

- (CGPoint)denorm:(float)nx y:(float)ny {
    return CGPointMake(nx * self.bounds.size.width,
                       ny * self.bounds.size.height);
}

- (CGPathRef)smoothPathForPoints:(NSArray<NSValue*>*)pts CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    NSUInteger n = pts.count;
    if (n == 0) return path;
    CGPoint p0 = [pts[0] CGPointValue];
    CGPathMoveToPoint(path, nil, p0.x, p0.y);
    if (n == 1) return path;
    if (n == 2) {
        CGPathAddLineToPoint(path, nil, [pts[1] CGPointValue].x, [pts[1] CGPointValue].y);
        return path;
    }
    for (NSUInteger i = 0; i < n - 1; ++i) {
        CGPoint curr = [pts[i]     CGPointValue];
        CGPoint next = [pts[i + 1] CGPointValue];
        CGPoint mid  = CGPointMake((curr.x + next.x) * 0.5f,
                                   (curr.y + next.y) * 0.5f);
        CGPathAddQuadCurveToPoint(path, nil, curr.x, curr.y, mid.x, mid.y);
    }
    CGPathAddLineToPoint(path, nil, [pts[n-1] CGPointValue].x, [pts[n-1] CGPointValue].y);
    return path;
}

- (void)updateLayer:(int)idx {
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
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
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    CAShapeLayer* layer = _strokeLayers[(NSUInteger)idx];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.path        = nil;
    layer.hidden      = NO;
    layer.strokeColor = [UIColor colorWithRed:0.39 green:0.90 blue:0.47 alpha:0.85].CGColor;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @YES;
}

- (void)addPoint:(CGPoint)pt toStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    if (![_strokeStarted[(NSUInteger)idx] boolValue]) return;
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    NSMutableArray<NSValue*>* pts = _strokePoints[(NSUInteger)idx];
    if (pts.count > 0) {
        CGPoint last = [pts.lastObject CGPointValue];
        if (hypot(pt.x - last.x, pt.y - last.y) < kMinPointDist) return;
    }
    [pts addObject:[NSValue valueWithCGPoint:pt]];
    [self updateLayer:idx];
}

- (void)completeStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    _strokeComplete[(NSUInteger)idx] = @YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].strokeColor =
        [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:1.0].CGColor;
    _strokeLayers[(NSUInteger)idx].hidden = NO;
    [CATransaction commit];
}

- (void)resetStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path   = nil;
    _strokeLayers[(NSUInteger)idx].hidden = YES;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @NO;
}

- (void)resetAll {
    [self hideMask];
    for (int i = 0; i < kMaxStrokes; ++i) {
        [_strokePoints[(NSUInteger)i] removeAllObjects];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _strokeLayers[(NSUInteger)i].path   = nil;
        _strokeLayers[(NSUInteger)i].hidden = YES;
        [CATransaction commit];
        _strokeStarted[(NSUInteger)i]  = @NO;
        _strokeComplete[(NSUInteger)i] = @NO;
    }
}

- (void)showMaskFromPBM:(NSString*)pbmPath {
    UIImage* img = greenImageFromPBM(pbmPath);
    if (!img) {
        NSLog(@"DrawingOverlay: could not load PBM at %@", pbmPath);
        return;
    }
    // Hide stroke layers — mask replaces them
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kMaxStrokes; ++i)
        _strokeLayers[(NSUInteger)i].hidden = YES;
    [CATransaction commit];

    _maskOverlay.image  = img;
    _maskOverlay.hidden = NO;

    // Fade in over 0.25s for a satisfying reveal
    _maskOverlay.alpha  = 0.0f;
    [UIView animateWithDuration:0.25 animations:^{
        self->_maskOverlay.alpha = 1.0f;
    }];
}

- (void)hideMask {
    _maskOverlay.hidden = YES;
    _maskOverlay.image  = nil;
    _maskOverlay.alpha  = 1.0f;
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
        gOverlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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

void drawing_overlay_show_mask(const char* pbmPath) {
    if (!pbmPath) return;
    NSString* path = [NSString stringWithUTF8String:pbmPath];
    on_main(^{ [gOverlay showMaskFromPBM:path]; });
}

void drawing_overlay_hide_mask(void) {
    on_main(^{ [gOverlay hideMask]; });
}


static const int   kMaxStrokes   = 8;
static const float kBrushWidth   = 40.0f;
static const float kMinPointDist = 10.0f;

// ---------------------------------------------------------------------------
@interface DrawingOverlayView : UIView
@property (nonatomic, strong) NSMutableArray<CAShapeLayer*>*             strokeLayers;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSValue*>*>* strokePoints;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*                 strokeStarted;
@property (nonatomic, strong) NSMutableArray<NSNumber*>*                 strokeComplete; // guard: never erase a done stroke
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
        self.backgroundColor        = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self setupLayers];
    }
    return self;
}

- (void)setupLayers {
    _strokeLayers   = [NSMutableArray array];
    _strokePoints   = [NSMutableArray array];
    _strokeStarted  = [NSMutableArray array];
    _strokeComplete = [NSMutableArray array];

    for (int i = 0; i < kMaxStrokes; ++i) {
        CAShapeLayer* layer = [CAShapeLayer layer];
        layer.fillColor     = [UIColor clearColor].CGColor;
        layer.strokeColor   = [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:0.9].CGColor;
        layer.lineWidth     = kBrushWidth;
        // kCALineCapButt: flush caps — no protrusion past endpoint, no scalloping
        layer.lineCap       = kCALineCapButt;
        layer.lineJoin      = kCALineJoinRound;
        layer.hidden        = YES;
        [self.layer addSublayer:layer];
        [_strokeLayers   addObject:layer];
        [_strokePoints   addObject:[NSMutableArray array]];
        [_strokeStarted  addObject:@NO];
        [_strokeComplete addObject:@NO];
    }
}

- (CGPoint)denorm:(float)nx y:(float)ny {
    return CGPointMake(nx * self.bounds.size.width,
                       ny * self.bounds.size.height);
}

- (CGPathRef)smoothPathForPoints:(NSArray<NSValue*>*)pts CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    NSUInteger n = pts.count;
    if (n == 0) return path;
    CGPoint p0 = [pts[0] CGPointValue];
    CGPathMoveToPoint(path, nil, p0.x, p0.y);
    if (n == 1) return path;
    if (n == 2) {
        CGPathAddLineToPoint(path, nil, [pts[1] CGPointValue].x, [pts[1] CGPointValue].y);
        return path;
    }
    for (NSUInteger i = 0; i < n - 1; ++i) {
        CGPoint curr = [pts[i]     CGPointValue];
        CGPoint next = [pts[i + 1] CGPointValue];
        CGPoint mid  = CGPointMake((curr.x + next.x) * 0.5f,
                                   (curr.y + next.y) * 0.5f);
        CGPathAddQuadCurveToPoint(path, nil, curr.x, curr.y, mid.x, mid.y);
    }
    CGPathAddLineToPoint(path, nil, [pts[n-1] CGPointValue].x, [pts[n-1] CGPointValue].y);
    return path;
}

- (void)updateLayer:(int)idx {
    // Never rebuild path for a completed stroke — it's permanently green as-is
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
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
    // Never restart a completed stroke
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    CAShapeLayer* layer = _strokeLayers[(NSUInteger)idx];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.path        = nil;
    layer.hidden      = NO;
    layer.strokeColor = [UIColor colorWithRed:0.39 green:0.90 blue:0.47 alpha:0.85].CGColor;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @YES;
}

- (void)addPoint:(CGPoint)pt toStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    if (![_strokeStarted[(NSUInteger)idx] boolValue]) return;
    // For completed strokes, still allow adding points but don't rebuild path
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    NSMutableArray<NSValue*>* pts = _strokePoints[(NSUInteger)idx];
    if (pts.count > 0) {
        CGPoint last = [pts.lastObject CGPointValue];
        if (hypot(pt.x - last.x, pt.y - last.y) < kMinPointDist) return;
    }
    [pts addObject:[NSValue valueWithCGPoint:pt]];
    [self updateLayer:idx];
}

- (void)completeStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    _strokeComplete[(NSUInteger)idx] = @YES;  // guard: this stroke is permanently done
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].strokeColor =
        [UIColor colorWithRed:0.24 green:0.82 blue:0.31 alpha:1.0].CGColor;
    _strokeLayers[(NSUInteger)idx].hidden = NO;
    [CATransaction commit];
}

- (void)resetStroke:(int)idx {
    if (idx < 0 || idx >= kMaxStrokes) return;
    // NEVER reset a completed stroke — this is the O green-persistence fix
    if ([_strokeComplete[(NSUInteger)idx] boolValue]) return;
    [_strokePoints[(NSUInteger)idx] removeAllObjects];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _strokeLayers[(NSUInteger)idx].path   = nil;
    _strokeLayers[(NSUInteger)idx].hidden = YES;
    [CATransaction commit];
    _strokeStarted[(NSUInteger)idx] = @NO;
}

- (void)resetAll {
    for (int i = 0; i < kMaxStrokes; ++i) {
        [_strokePoints[(NSUInteger)i] removeAllObjects];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _strokeLayers[(NSUInteger)i].path   = nil;
        _strokeLayers[(NSUInteger)i].hidden = YES;
        [CATransaction commit];
        _strokeStarted[(NSUInteger)i]  = @NO;
        _strokeComplete[(NSUInteger)i] = @NO;
    }
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
        gOverlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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
