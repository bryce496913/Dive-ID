import XCTest
@testable import DiveID

final class CatalogueAttributionTests: XCTestCase {
    func testCreditsNameBothSourcesTheReleaseLicenceAndChanges() {
        XCTAssertEqual(CatalogueAttribution.credits.map(\.name), ["FishBase", "SeaLifeBase"])
        XCTAssertTrue(CatalogueAttribution.credits.allSatisfy { $0.release == "v26.06" && $0.citation.contains("Pauly") })
        XCTAssertEqual(CatalogueAttribution.licenseURL, "https://creativecommons.org/licenses/by-nc/4.0/")
        XCTAssertTrue(CatalogueAttribution.licenseNotice.contains("CC BY-NC 4.0"))
        XCTAssertTrue(CatalogueAttribution.modificationNotice.contains("changed"))
    }

    /// Every Global record, approved or not, links to its source page and licence.
    func testEveryGlobalRecordLinksToItsSourcePage() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let pack = try await repository.loadPack(id: .global)
        XCTAssertFalse(pack.profiles.isEmpty)
        // The 8 Caribbean species are the Caribbean pack's own records, carried into Global
        // with their own sources; they must credit exactly what the Caribbean pack credits.
        let caribbean = Dictionary(uniqueKeysWithValues: try await repository.loadPack(id: .caribbean).profiles.map { ($0.id, $0) })
        for profile in pack.profiles {
            let lines = CatalogueAttribution.sourceLines(for: profile.dataSources)
            XCTAssertFalse(lines.isEmpty, profile.commonName)
            if let regional = caribbean[profile.id] {
                let expected = CatalogueAttribution.sourceLines(for: regional.dataSources)
                XCTAssertEqual(lines.map(\.text), expected.map(\.text), profile.commonName)
                XCTAssertEqual(lines.map(\.url), expected.map(\.url), profile.commonName)
                XCTAssertTrue(lines.allSatisfy { $0.url != nil }, profile.commonName)
                continue
            }
            for line in lines {
                let url = try XCTUnwrap(line.url, profile.commonName)
                XCTAssertTrue(["www.fishbase.se", "www.sealifebase.se"].contains(url.host ?? ""), "\(profile.commonName): \(url)")
                XCTAssertTrue(line.text.contains("CC BY-NC 4.0"), profile.commonName)
            }
        }
    }

    private func photo(_ name: String, license: String = "CC BY-NC 4.0") -> BundledSpeciesImage {
        BundledSpeciesImage(fileName: name, alternativeText: "Photo of a fish", creatorName: "Jane Diver", sourceName: "iNaturalist",
                            sourceURL: "https://www.inaturalist.org/photos/1", licenseName: license,
                            licenseURL: "https://creativecommons.org/licenses/by-nc/4.0/",
                            photoURL: "https://inaturalist-open-data.s3.amazonaws.com/photos/1/large.jpg",
                            photoID: "inaturalist:photo:1", observationID: "inaturalist:observation:1", retrievedDate: "2026-10-27")
    }

    private func globalProfiles(_ count: Int) async throws -> [LocalSpeciesProfile] {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        return Array(try await repository.loadPack(id: .global).profiles.prefix(count))
    }

    /// Photo licences follow Tools/SpeciesPhotos/photo_policy.json: CC0, CC BY and CC BY-NC
    /// are accepted; share-alike (a later decision), no-derivatives and unknown are not.
    func testOnlyAllowedPhotoLicencesValidate() async throws {
        var profile = try await globalProfiles(1)[0]
        profile.similarSpecies = []  // validated alone, so no references to other records
        for license in ["CC0 1.0", "CC BY 4.0", "CC BY-NC 4.0"] {
            profile.bundledImage = photo("a-inat-1.jpg", license: license)
            XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]), license)
        }
        for license in ["CC BY-SA 4.0", "CC BY-NC-SA 4.0", "CC BY-ND 4.0", "CC BY-NC-ND 4.0", "All rights reserved", ""] {
            profile.bundledImage = photo("a-inat-1.jpg", license: license)
            XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile]), license)
        }
        var noCreator = photo("a-inat-1.jpg")
        noCreator = BundledSpeciesImage(fileName: noCreator.fileName, alternativeText: noCreator.alternativeText, creatorName: " ",
                                        sourceName: noCreator.sourceName, sourceURL: noCreator.sourceURL,
                                        licenseName: noCreator.licenseName, licenseURL: noCreator.licenseURL)
        profile.bundledImage = noCreator
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile])) {
            XCTAssertEqual($0 as? LocalCatalogError, .emptyImageAttribution)
        }
    }

    func testPhotoAttributionDecodesWithAndWithoutTheSourceFields() throws {
        let image = photo("a-inat-1.jpg")
        let decoded = try JSONDecoder().decode(BundledSpeciesImage.self, from: JSONEncoder().encode(image))
        XCTAssertEqual(decoded, image)
        XCTAssertEqual(decoded.photoID, "inaturalist:photo:1")
        XCTAssertEqual(decoded.retrievedDate, "2026-10-27")
        XCTAssertTrue(decoded.isPhoto)
        let artwork = Data(#"{"fileName":"queen.svg","alternativeText":"A","creatorName":"Dive ID","sourceName":"Dive ID","sourceURL":"https://example.org","licenseName":"CC0","licenseURL":"https://creativecommons.org/publicdomain/zero/1.0/"}"#.utf8)
        let svg = try JSONDecoder().decode(BundledSpeciesImage.self, from: artwork)
        XCTAssertNil(svg.photoURL)
        XCTAssertFalse(svg.isPhoto, "SVG artwork is not a photo")
        XCTAssertEqual(image.creditLine, "Jane Diver · CC BY-NC 4.0 · iNaturalist")
    }

    /// Credits list each bundled photo once, by species name, and leave out SVG artwork.
    func testCreditsListEachBundledPhotoOnce() async throws {
        var profiles = try await globalProfiles(3)
        profiles[0].bundledImage = photo("b-inat-2.jpg")
        profiles[1].bundledImage = photo("a-inat-1.jpg")
        profiles[2].bundledImage = BundledSpeciesImage(fileName: "art.svg", alternativeText: "A", creatorName: "Dive ID", sourceName: "Dive ID",
                                                       sourceURL: "https://example.org", licenseName: "CC0",
                                                       licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/")
        let metadata = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment).loadPack(id: .global).metadata
        let global = OfflineIdentificationPack(metadata: metadata, profiles: profiles)
        let region = OfflineIdentificationPack(metadata: metadata, profiles: [profiles[0]])
        let credits = CatalogueAttribution.photoCredits(in: [global, region])
        let expected = [profiles[0], profiles[1]].sorted { $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending }
        XCTAssertEqual(credits.map(\.commonName), expected.map(\.commonName))
        XCTAssertTrue(credits.allSatisfy { $0.image.creatorName == "Jane Diver" && $0.image.licenseName == "CC BY-NC 4.0" })
        XCTAssertTrue(CatalogueAttribution.photoCredits(in: []).isEmpty)
    }

    /// Only approved photos are bundled (Tools/FishBaseIntake/publish_global.py), so every
    /// photo in the shipped packs carries complete attribution and an allowed licence.
    func testEveryBundledGlobalPhotoIsFullyAttributed() async throws {
        for profile in try await globalProfiles(Int.max) {
            guard let image = profile.bundledImage else { continue }
            XCTAssertTrue(image.isPhoto, profile.commonName)
            XCTAssertTrue(["CC0 1.0", "CC BY 4.0", "CC BY-NC 4.0"].contains(image.licenseName), profile.commonName)
            for value in [image.creatorName, image.sourceURL, image.licenseURL, image.photoURL, image.photoID, image.observationID, image.retrievedDate] {
                XCTAssertFalse((value ?? "").trimmingCharacters(in: .whitespaces).isEmpty, profile.commonName)
            }
            XCTAssertTrue(image.alternativeText.contains(profile.commonName), profile.commonName)
        }
    }
}
