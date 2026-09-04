// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiveIDBenchmark",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DiveID", targets: ["DiveID"])],
    targets: [
        .target(
            name: "DiveID",
            path: "DiveID",
            exclude: [
                "App", "Features", "Resources", "Core/Components", "Core/Theme",
                "Core/Services/BundleSpeciesImageLoader.swift",
                "Core/Services/PhotoProcessingService.swift",
                "Core/Services/SavedSpeciesRepository.swift",
                "Core/Services/SelectedDiveRegionRepository.swift",
                "Info.plist"
            ],
            sources: [
                "Core/Catalog/Schema/CatalogueVocabulary.swift",
                "Core/Catalog/Schema/RegionCatalogDefinition.swift",
                "Core/Catalog/Regions/RegionCatalogRegistry.swift",
                "Core/Catalog/Regions/CaribbeanRegion.swift",
                "Core/Models/LocalSpeciesProfile.swift",
                "Core/Models/Models.swift",
                "Core/Models/OfflineIdentificationPack.swift",
                "Core/Models/ParsedObservation.swift",
                "Core/Services/IdentificationService.swift",
                "Core/Services/IdentificationSessionStore.swift",
                "Core/Services/BundleMarineSpeciesCatalogRepository.swift",
                "Core/Services/LocalMarineLifeIdentificationService.swift",
                "Core/Services/LocalObservationParser.swift",
                "Core/Services/LocalSpeciesRanker.swift",
                "Core/Services/MarineSpeciesCatalogRepository.swift",
                "Core/Services/MockSpecies.swift",
                "Core/Services/RegionCompatibilityResolver.swift"
            ]
        ),
        .testTarget(
            name: "IdentificationBenchmarkTests",
            dependencies: ["DiveID"],
            path: "DiveIDTests",
            exclude: [
                "CanonicalSpeciesSchemaTests.swift", "DiveIDTests.swift", "OfflineIdentificationPackTests.swift",
                "SavedIdentificationCompatibilityTests.swift", "Fixtures"
            ],
            sources: ["IdentificationBenchmarkTests.swift", "ProductionDescriptionSearchTests.swift"]
        )
    ]
)
