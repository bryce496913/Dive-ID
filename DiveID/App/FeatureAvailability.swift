import Foundation

struct FeatureAvailability: Sendable {
    let photoIdentificationEnabled: Bool

    static let current = FeatureAvailability(photoIdentificationEnabled: false)
}
