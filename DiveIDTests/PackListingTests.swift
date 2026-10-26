import Foundation
import XCTest
@testable import DiveID

/// `availablePacks()` lists packs from their manifests; full validation runs once when
/// a pack is first opened. Listing results must equal those built from fully validated
/// records, and every invalid pack must still fail closed.
final class PackListingTests: XCTestCase {
    private typealias Access = BundleMarineSpeciesCatalogRepository.CatalogueAccess

    private func production(_ access: Access) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
    }

    /// A copy of the Caribbean pack whose files a test may break.
    private func caribbeanCopy(_ access: Access, edit: (URL) throws -> Void) throws -> BundleMarineSpeciesCatalogRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        let destination = root.appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("IdentificationPacks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try edit(destination)
        return BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: PackListingTests.self),
            registry: RegionCatalogRegistry(definitions: [RegionCatalogDefinition(id: .caribbean, resourceDirectory: "Caribbean")]),
            resourceResolutionMode: .bundleThenDevelopmentSource, developmentSourceRoot: root, access: access)
    }

    private func editManifest(_ directory: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("PackManifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    private func failureCode(_ body: () async throws -> Void) async -> CatalogueDiagnosticCode? {
        do { try await body(); return nil } catch let failure as CatalogueLoadFailure { return failure.code } catch { return nil }
    }

    func testListingFromManifestsEqualsListingFromValidatedRecords() async throws {
        for access in [Access.experimentalDevelopment, .publication] {
            let lazy = try await production(access).availablePacks()
            let validated = production(access)
            for definition in RegionCatalogRegistry.bundled.definitions { _ = try? await validated.loadPack(id: definition.id) }
            let fromRecords = try await validated.availablePacks()
            XCTAssertEqual(lazy, fromRecords, "\(access)")
        }
        let release = try await production(.publication).availablePacks()
        XCTAssertEqual(release.map(\.id), [.global, .tropicalAtlantic, .indoPacific, .pacificCoast, .mediterranean],
                       "Release lists Global and its regions; retired regions never")
        XCTAssertTrue(release.allSatisfy { $0.speciesCount == $0.publicationEligibleRecordCount })
    }

    func testManifestAccountingProblemsStillFailTheListing() async throws {
        let inconsistent = try caribbeanCopy(.experimentalDevelopment) { try self.editManifest($0) { $0["humanReviewedRecordCount"] = 0 } }
        let code1 = await failureCode { _ = try await inconsistent.availablePacks() }
        XCTAssertEqual(code1, .reviewAccountingInvalid)
        let missing = try caribbeanCopy(.publication) { try self.editManifest($0) { $0.removeValue(forKey: "publicationEligibleRecordCount") } }
        let code2 = await failureCode { _ = try await missing.availablePacks() }
        XCTAssertEqual(code2, .reviewAccountingInvalid)
        let noRecords = try caribbeanCopy(.experimentalDevelopment) { try FileManager.default.removeItem(at: $0.appendingPathComponent("Creatures.json")) }
        let code3 = await failureCode { _ = try await noRecords.availablePacks() }
        XCTAssertEqual(code3, .speciesResourceMissing)
    }

    func testCorruptRecordsFailClosedWhenThePackIsOpened() async throws {
        let corrupt = try caribbeanCopy(.experimentalDevelopment) { try Data("not json".utf8).write(to: $0.appendingPathComponent("Creatures.json")) }
        let listed = try await corrupt.availablePacks()
        XCTAssertEqual(listed.map(\.id), [.caribbean], "listing reads only the manifest")
        let code = await failureCode { _ = try await corrupt.loadPack(id: .caribbean) }
        XCTAssertEqual(code, .decodeFailed)
    }

    func testReleaseManifestThatOverstatesApprovalsFailsClosedWhenOpened() async throws {
        // Records all draft, manifest still claiming 2 approved records.
        let overstated = try caribbeanCopy(.publication) { directory in
            let url = directory.appendingPathComponent("Creatures.json")
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            for i in records.indices { records[i]["review"] = ["status": "draft", "reviewerNotes": NSNull(), "reviewDate": NSNull(), "verifiedBy": NSNull()] }
            try JSONSerialization.data(withJSONObject: records).write(to: url)
            try self.editManifest(directory) { $0["humanReviewedRecordCount"] = 2; $0["publicationEligibleRecordCount"] = 2 }
        }
        let listed = try await overstated.availablePacks()
        XCTAssertEqual(listed.first?.speciesCount, 2, "the manifest's claim is listed")
        let code = await failureCode { _ = try await overstated.loadPack(id: .caribbean) }
        XCTAssertEqual(code, .reviewAccountingInvalid, "no draft is ever exposed")
        let after = await failureCode { _ = try await overstated.availablePacks() }
        XCTAssertEqual(after, .reviewAccountingInvalid, "once the records have been read, the listing fails as it did before")
    }
}
