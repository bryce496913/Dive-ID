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

Xcode setup
-----------
The launch assets live directly in the app's Assets.xcassets catalog. Info.plist
uses the UILaunchScreen dictionary to display LaunchScreen over LaunchBackground;
no launch storyboard or runtime code is required.

Palette
-------
Background: #000000
Surface:    #1F0A33
Accent:     #B84AF2
Highlight:  #FA52AB
Text:       #FFFFFF
