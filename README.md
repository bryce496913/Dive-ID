# Dive ID iOS V0.1

Open `DiveID.xcodeproj` in Xcode 16 or newer. The app targets iOS 18 and uses only Apple frameworks. The primary MVP sends written observations to the Dive ID backend, which keeps provider credentials server-side and returns validated ranked candidates. Suggestions may be inaccurate and are not authoritative scientific identifications.

## AI description identification

`DiveID/Configuration/Debug.xcconfig` and `Release.xcconfig` are assigned to the app target. Debug defaults to deterministic mock description results, so a fresh clone works without a server. Copy `Local.example.xcconfig` to the ignored `Local.xcconfig` to opt into the local backend. Release is always remote: CI or a protected build environment injects `DIVE_ID_PRODUCTION_API_BASE_URL` as an HTTPS origin. Missing/invalid remote configuration is reported distinctly from an outage. The backend URL is public routing configuration; `AI_API_KEY` is a backend secret and never belongs in iOS. No broad ATS exception is used.

For local remote-mode development: (1) `cd backend && npm ci`; (2) `cp .env.example .env` and configure the provider; (3) `npm run dev`; (4) verify `curl http://127.0.0.1:8080/health`; (5) copy the example local xcconfig; (6) run Debug and submit a description.

Production description identification is supported. Photo selection/preprocessing infrastructure is preserved, but the Home card is disabled and marked **Coming later**; camera capture remains out of scope.

## Foundation architecture

Dive ID retains its feature-based SwiftUI structure. Several view and view-model types remain co-located in the original consolidated feature files rather than being split into every filename suggested by the architecture brief. The app continues to use one typed `NavigationStack` and protocol-backed dependencies.

Identification input screens create temporary sessions only. A lightweight session UUID is routed to the results feature, which resolves the request and optional processed photo, runs the injected service once, and caches the sorted first ten matches in the actor-backed session. Reopening a completed session reads that result instead of calling the service again; an explicit retry is available after failure.

Photos are decoded and orientation-corrected with Image I/O away from the main actor, then newly encoded as metadata-free JPEG data. Preview images are bounded to 1,200 pixels and identification uploads to 2,048 pixels at 0.8 quality. The in-memory session store owns these bytes; neither `UIImage` nor image data enters navigation state.

Saved identifications retain species, rank, match evidence, original observation, date, and optional notes in a versioned JSON envelope. Actor-isolated atomic writes remain; version-1 species records migrate with an explicit legacy-evidence note, while corrupt data is preserved.

The initial V0.1 target is intentionally iPhone-only. The existing app requires full screen and the major screens have not yet received an iPad layout validation pass. Camera capture remains visibly unavailable and does not request permission.

GitHub Actions builds and runs unit tests on an iPhone 16 simulator. UI tests remain available in the project but are excluded from CI to avoid simulator automation instability; they use deterministic mock launch modes when run locally.
