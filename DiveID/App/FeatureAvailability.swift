import Foundation

struct FeatureAvailability: Sendable {
    let descriptionIdentificationEnabled: Bool
    let photoIdentificationEnabled: Bool

    static let current = FeatureAvailability(
        descriptionIdentificationEnabled: true,
        photoIdentificationEnabled: false
    )
}
