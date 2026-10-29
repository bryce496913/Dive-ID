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
    static func retiredDiveRegionMessage(_ retired: String) -> String {
        "\(retired) is no longer offered as a dive region. Choose another dive region to continue."
    }
    static func retiredDiveRegionMessage(_ retired: String, suggestion: String) -> String {
        "\(retired) is no longer offered as a dive region. Its species are now in \(suggestion), or choose another dive region to continue."
    }
    static func useSuggestedDiveRegion(_ name: String) -> String { "Use \(name)" }

    static let sessionCapacityReached = "Finish an existing search by going back before starting another."

    /// Possible matches are suggestions, never confirmed identifications.
    static let accuracyDisclaimer = "Possible matches are suggestions, not confirmed identifications. Compare distinguishing features and confirm important sightings with a qualified local guide or trusted reference."
    /// Match strength is relative clue similarity, not a probability.
    static let matchStrengthDisclaimer = "Match strength reflects similarity to the clues in your description. It is not a probability or a confirmed identification."
    /// Photo results: the same disclaimers apply; this says what the strength means for a photo.
    static let photoMatchStrengthDisclaimer = "Match strength reflects how similar your photo looks to the reference photos, and any clues you added. It is not a probability or a confirmed identification. A photo alone never shows more than a possible match."
    static func photoCoverage(covered: Int, total: Int) -> String {
        "Photo matching covers \(covered.formatted()) of \(total.formatted()) species. If you don't see it, try describing it."
    }
    static let noConfidentPhotoMatchTitle = "No confident photo match"
    static let noConfidentPhotoMatchMessage = "The photo didn't look similar enough to any reference photo to suggest a species. Try another photo, or describe what you saw."
    static let photoResultsFromDescription = "No confident photo match. These results come from what you described."
    static let placeholderRecognizerWarning = "Test recognizer: these photo results are placeholders, not real matches"
    static let describeItInstead = "Describe It Instead"
    /// Draft records have not been human-verified.
    static let draftCatalogueWarning = "Draft catalogue — identities and biological details have not been verified"
    static func draftRecordStatus(_ status: String) -> String {
        "\(status) — draft record; identity and biological details have not been verified"
    }
    /// Says "individually reviewed" only where a person read this record. A
    /// sample-approved record was approved with its batch without being read.
    static func recordReviewStatus(_ review: RecordReview) -> String {
        guard review.status == .verified else { return draftRecordStatus(review.status.rawValue.capitalized) }
        switch review.reviewMethod {
        case .individuallyReviewed: return "Approved for publication — individually reviewed"
        case .sampleApproved: return "Approved for publication as part of a reviewed batch — this record was not individually reviewed"
        case nil: return "Human-reviewed and approved for publication"
        }
    }
}
