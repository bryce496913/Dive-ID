import Foundation

/// User-facing messages shown on more than one screen, or whose safety meaning
/// must stay identical wherever they appear.
///
/// Vocabulary: the user picks a "dive region"; its species data is the "offline
/// catalogue" ("reviewed catalogue" when review status matters); results are
/// "possible matches"; unverified records are "draft"; kept results are
/// "saved identifications".
enum AppCopy {
    static let tryAgain = "Try Again"

    static let catalogueLoadFailed = "The offline catalogue could not be loaded."
    static let diveRegionsLoadFailed = "Dive regions could not be loaded."

    static let noReviewedCatalogueTitle = "No reviewed catalogue available"
    static let noReviewedCatalogueMessage = "No human-reviewed offline catalogue is currently available, so no search can be run. Saved identifications remain available."

    static let diveRegionUnavailableTitle = "Dive region unavailable"
    static let diveRegionUnavailableMessage = "The selected dive region has no reviewed catalogue. Choose another dive region to continue."

    static let sessionCapacityReached = "Finish an existing search by going back before starting another."

    /// Possible matches are suggestions, never confirmed identifications.
    static let accuracyDisclaimer = "Possible matches are suggestions, not confirmed identifications. Compare distinguishing features and confirm important sightings with a qualified local guide or trusted reference."
    /// Match strength is relative clue similarity, not a probability.
    static let matchStrengthDisclaimer = "Match strength reflects similarity to the clues in your description. It is not a probability or a confirmed identification."
    /// Draft records have not been human-verified.
    static let draftCatalogueWarning = "Draft catalogue — identities and biological details have not been verified"
    static func draftRecordStatus(_ status: String) -> String {
        "\(status) — draft record; identity and biological details have not been verified"
    }
}
