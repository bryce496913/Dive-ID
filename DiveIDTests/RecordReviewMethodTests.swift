import Foundation
import XCTest
@testable import DiveID

/// The species detail claims "individually reviewed" only where batch review recorded it.
final class RecordReviewMethodTests: XCTestCase {
    private func review(_ status: RecordReviewStatus, _ method: RecordReviewMethod?) -> RecordReview {
        RecordReview(status: status, reviewerNotes: "notes", reviewDate: Date(timeIntervalSince1970: 0), verifiedBy: "Bryce", reviewMethod: method)
    }

    func testDetailStatusReflectsTheReviewMethodTruthfully() {
        let individual = AppCopy.recordReviewStatus(review(.verified, .individuallyReviewed))
        XCTAssertEqual(individual, "Approved for publication — individually reviewed")

        let sampled = AppCopy.recordReviewStatus(review(.verified, .sampleApproved))
        XCTAssertTrue(sampled.hasPrefix("Approved for publication"))
        XCTAssertTrue(sampled.contains("not individually reviewed"))
        XCTAssertFalse(sampled.contains("— individually reviewed"))

        // Records approved before batch review keep their existing wording and make no method claim.
        XCTAssertEqual(AppCopy.recordReviewStatus(review(.verified, nil)), "Human-reviewed and approved for publication")
        XCTAssertEqual(AppCopy.recordReviewStatus(review(.draft, nil)), AppCopy.draftRecordStatus("Draft"))
    }

    func testReviewMethodDecodesFromTheOverlaySpelling() throws {
        let json = #"{"status":"verified","reviewerNotes":"n","reviewDate":null,"verifiedBy":"Bryce","reviewMethod":"sample-approved"}"#
        XCTAssertEqual(try JSONDecoder().decode(RecordReview.self, from: Data(json.utf8)).reviewMethod, .sampleApproved)
        let legacy = #"{"status":"draft","reviewerNotes":null,"reviewDate":null,"verifiedBy":null}"#
        XCTAssertNil(try JSONDecoder().decode(RecordReview.self, from: Data(legacy.utf8)).reviewMethod)
        XCTAssertThrowsError(try JSONDecoder().decode(RecordReview.self, from: Data(json.replacingOccurrences(of: "sample-approved", with: "skimmed").utf8)))
    }

    func testCatalogueRejectsAReviewMethodOnAnUnapprovedRecord() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let profiles = try await repository.loadPack(id: .caribbean).profiles
        var approved = try XCTUnwrap(profiles.first { $0.review?.status == .verified })
        approved.review?.reviewMethod = .individuallyReviewed
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([approved]))
        var draft = try XCTUnwrap(profiles.first { $0.review?.status == .draft })
        draft.review?.reviewMethod = .sampleApproved
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([draft])) { XCTAssertEqual($0 as? LocalCatalogError, .unverifiedRecord) }
    }
}
