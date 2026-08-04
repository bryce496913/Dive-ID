# Dive ID iOS V0.1

Open `DiveID.xcodeproj` in Xcode 16 or newer. The app targets iOS 18 and uses only Apple frameworks. Identification remains a deterministic local mock; selected photos stay on the device and are never uploaded.

## Foundation architecture

Dive ID retains its feature-based SwiftUI structure. Several view and view-model types remain co-located in the original consolidated feature files rather than being split into every filename suggested by the architecture brief. The app continues to use one typed `NavigationStack` and protocol-backed dependencies.

Identification input screens create temporary sessions only. A lightweight session UUID is routed to the results feature, which resolves the request and optional processed photo, runs the local mock service once, and caches the sorted first ten matches in the actor-backed session. Reopening a completed session reads that result instead of calling the service again; an explicit retry is available after failure.

Photos are decoded and orientation-corrected with Image I/O away from the main actor, then newly encoded as metadata-free JPEG data. Preview images are bounded to 1,200 pixels and identification uploads to 2,048 pixels at 0.8 quality. The in-memory session store owns these bytes; neither `UIImage` nor image data enters navigation state.

Saved species use a versioned JSON envelope in Application Support. Repository operations are actor-isolated, writes use a same-directory temporary file and atomic replacement, and corrupt data is reported rather than overwritten.

The initial V0.1 target is intentionally iPhone-only. The existing app requires full screen and the major screens have not yet received an iPad layout validation pass. Camera capture remains visibly unavailable and does not request permission.

GitHub Actions builds and runs unit tests on an iPhone 16 simulator. UI tests remain available in the project but are excluded from CI to avoid simulator automation instability; they use deterministic mock launch modes when run locally.
