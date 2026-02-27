// TouchVisualizer.h
// Temporary touch visualization for screen recording.
// Remove before App Store submission.
// Call touch_visualizer_install(sdlView) once after SDL view is ready.
// Call touch_visualizer_remove() to tear it down.

#pragma once
#ifdef __OBJC__
#import <UIKit/UIKit.h>
void touch_visualizer_install(UIView* sdlView);
void touch_visualizer_remove(void);
#endif
