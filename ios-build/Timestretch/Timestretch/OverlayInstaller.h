// OverlayInstaller.h
// Finds the SDL UIView after the window is shown and installs the DrawingOverlay on top.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Call once after SDL_CreateWindow + SDL_CreateRenderer succeed.
/// Walks the UIKit view hierarchy to find the SDL metal/UIKit view and
/// attaches the DrawingOverlayView on top of it.
void overlay_installer_attach(void);

#ifdef __cplusplus
}
#endif
