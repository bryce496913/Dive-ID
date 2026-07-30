Launch Screen Assets
====================

Contents
--------
LaunchScreen.imageset
  Full-screen launch artwork at 1x, 2x, and 3x.

LaunchLogo.imageset
  Transparent app-logo artwork at 1x, 2x, and 3x.

LaunchBackground.colorset
  Black background matching the app theme.

LaunchSurface.colorset
LaunchAccent.colorset
LaunchHighlight.colorset
  Supporting theme colors matching the SwiftUI palette.

Recommended Xcode setup
-----------------------
1. Drag LaunchScreenAssets.xcassets into the Xcode project.
2. In the target settings, set Launch Screen File to your LaunchScreen storyboard.
3. Add a full-screen UIImageView using LaunchScreen, or compose the screen with
   LaunchBackground plus a centered UIImageView using LaunchLogo.
4. Set the image view content mode to Aspect Fill for LaunchScreen or Aspect Fit
   for LaunchLogo.
5. Do not add dynamic text, timers, or animations to the launch storyboard.

Palette
-------
Background: #000000
Surface:    #1F0A33
Accent:     #B84AF2
Highlight:  #FA52AB
Text:       #FFFFFF
