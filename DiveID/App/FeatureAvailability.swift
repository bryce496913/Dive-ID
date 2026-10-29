import Foundation

struct FeatureAvailability: Sendable {
    let photoIdentificationEnabled: Bool

    /// Photo identification runs only in Debug and Internal builds. Release keeps "Coming later".
    static func forChannel(_ channel: BuildChannel) -> FeatureAvailability {
        FeatureAvailability(photoIdentificationEnabled: channel != .release)
    }

    static let current: FeatureAvailability = {
#if DEBUG
        // UI tests check the Release home screen with -photoIdentificationDisabled.
        if ProcessInfo.processInfo.arguments.contains("-photoIdentificationDisabled") {
            return FeatureAvailability(photoIdentificationEnabled: false)
        }
#endif
        return forChannel(.current)
    }()
}
