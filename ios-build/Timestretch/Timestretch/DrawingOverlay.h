// DrawingOverlay.h
// Transparent UIView that draws the green stroke painting on top of the SDL view.
// Coordinate space: normalised [0,1] matching the SDL mask space.
// Thread-safety: all public functions must be called from the MAIN thread.

#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Call once after the SDL window is up. Installs the overlay above sdlView.
void drawing_overlay_install(UIView* sdlView);

/// Start a new in-progress stroke (clears any previous in-progress paint for that stroke).
/// strokeIndex: 0-based index matching StrokeTracker::progress index.
void drawing_overlay_begin_stroke(int strokeIndex);

/// Add a normalised point [0,1] to the currently active stroke.
void drawing_overlay_add_point(int strokeIndex, float nx, float ny);

/// Mark a stroke as complete (paint stays, colour changes to solid green).
void drawing_overlay_complete_stroke(int strokeIndex);

/// Reset a stroke (erase its paint, e.g. finger lifted mid-stroke).
void drawing_overlay_reset_stroke(int strokeIndex);

/// Reset all strokes (new letter loaded).
void drawing_overlay_reset_all(void);

/// Show the full letter mask as a solid green overlay (call when all strokes complete).
/// pbmPath: absolute path to the P4 binary PBM file for the current letter.
void drawing_overlay_show_mask(const char* pbmPath);

/// Hide the mask overlay (called automatically by reset_all).
void drawing_overlay_hide_mask(void);

#ifdef __cplusplus
}
#endif
