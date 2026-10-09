// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiveIDBenchmark",
    // Observation-backed saved-state models require macOS 14 in the portable test harness.
    platforms: [.macOS(.v14)],
    products: [.library(name: "DiveID", targets: ["DiveID"])],
    targets: [
        .target(
            name: "DiveID",
            path: "DiveID",
            exclude: [
                "App/DebugSemanticSearchStatusView.swift", "App/DiveIDApp.swift", "App/RootView.swift", "App/FeatureAvailability.swift", "Features", "Resources/Assets.xcassets", "Core/Components", "Core/Theme",
                "Core/Services/BundleSpeciesImageLoader.swift",
                "Core/Services/PhotoProcessingService.swift",
                "Core/Services/SelectedDiveRegionRepository.swift",
                "Info.plist"
            ],
            sources: [
                "Core/Catalog/Schema/CatalogueVocabulary.swift",
                "Core/Catalog/Schema/RegionCatalogDefinition.swift",
                "Core/Catalog/Regions/RegionCatalogRegistry.swift",
                "Core/Catalog/Regions/CaribbeanRegion.swift",
                "Core/Catalog/Regions/TropicalPacificRegion.swift",
                "Core/Models/LocalSpeciesProfile.swift",
                "Core/Models/Models.swift",
                "Core/Models/IdentificationResultsViewModel.swift",
                "App/AppRouter.swift",
                "Core/Models/SavedIdentificationViewModels.swift",
                "Core/Services/SavedSpeciesRepository.swift",
                "Core/Models/OfflineIdentificationPack.swift",
                "Core/Models/ParsedObservation.swift",
                "Core/Models/SpeciesSearchDocument.swift",
                "Core/Services/IdentificationService.swift",
                "Core/Services/IdentificationSessionStore.swift",
                "Core/Services/BundleMarineSpeciesCatalogRepository.swift",
                "Core/Services/LocalMarineLifeIdentificationService.swift",
                "Core/Services/DescriptionSearchEngine.swift",
                "Core/Services/SpeciesCandidateRetriever.swift",
                "Core/Services/SemanticCandidateRetriever.swift",
                "Core/Services/CoreMLSemanticEmbeddingProvider.swift",
                "Core/Services/SemanticRetrievalRuntime.swift",
                "Core/Services/LocalObservationParser.swift",
                "Core/Services/LocalSpeciesRanker.swift",
                "Core/Services/MarineSpeciesCatalogRepository.swift",
                "Core/Services/MockSpecies.swift",
                "Core/Services/RegionCompatibilityResolver.swift"
            ],
            resources: [.copy("Resources/IdentificationPacks")]
        ),
        .testTarget(
            name: "IdentificationBenchmarkTests",
            dependencies: ["DiveID"],
            path: "DiveIDTests",
            exclude: [
                "CanonicalSpeciesSchemaTests.swift", "DiveIDTests.swift", "OfflineIdentificationPackTests.swift"
            ],
            sources: ["IdentificationLifecycleTests.swift", "SavedIdentificationPersistenceTests.swift", "SavedIdentificationCompatibilityTests.swift", "IdentificationBenchmarkTests.swift", "ProductionDescriptionSearchTests.swift", "DescriptionSearchArchitectureTests.swift", "SemanticSearchTests.swift", "TropicalPacificCatalogueTests.swift", "LocalObservationParserTests.swift", "TestResources.swift"],
            resources: [.copy("Fixtures")]
        )
    ]
)
