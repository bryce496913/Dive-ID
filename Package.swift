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
                "Core/Services/SpeciesThumbnailCache.swift",
                "Core/Services/PhotoProcessingService.swift",
                "Info.plist",
                "PrivacyInfo.xcprivacy"
            ],
            sources: [
                "Core/Catalog/Schema/CatalogueVocabulary.swift",
                "Core/Catalog/Schema/RegionCatalogDefinition.swift",
                "Core/Catalog/Regions/RegionCatalogRegistry.swift",
                "Core/Catalog/Regions/CaribbeanRegion.swift",
                "Core/Catalog/Regions/TropicalPacificRegion.swift",
                "Core/Catalog/Regions/GlobalRegion.swift",
                "Core/Catalog/Regions/GlobalSubregions.swift",
                "Core/Models/BuildChannel.swift",
                "Core/Models/LocalSpeciesProfile.swift",
                "Core/Models/Models.swift",
                "Core/Models/IdentificationResultsViewModel.swift",
                "App/AppRouter.swift",
                "Core/Models/SavedIdentificationViewModels.swift",
                "Core/Services/SavedSpeciesRepository.swift",
                "Core/Models/OfflineIdentificationPack.swift",
                "Core/Models/SelectedPackState.swift",
                "Core/Models/SpeciesCatalogueViewModel.swift",
                "Core/Models/FieldGuide.swift",
                "Core/Models/DiveLog.swift",
                "Core/Models/DiverFeedback.swift",
                "Core/Services/DiverFeedbackRepository.swift",
                "Core/Services/DiverFeedbackService.swift",
                "Core/Models/AppCopy.swift",
                "Core/Models/CatalogueAttribution.swift",
                "Core/Services/SelectedDiveRegionRepository.swift",
                "Core/Models/ParsedObservation.swift",
                "Core/Models/SpeciesSearchDocument.swift",
                "Core/Services/IdentificationService.swift",
                "Core/Services/IdentificationSessionStore.swift",
                "Core/Services/BundleMarineSpeciesCatalogRepository.swift",
                "Core/Services/LocalMarineLifeIdentificationService.swift",
                "Core/Services/DescriptionSearchEngine.swift",
                "Core/Services/SpeciesCandidateRetriever.swift",
                "Core/Services/SearchIndexStore.swift",
                "Core/Services/SearchPerformanceInstrumentation.swift",
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
            sources: ["V05DevelopmentEvaluationTests.swift", "IdentificationLifecycleTests.swift", "SavedIdentificationPersistenceTests.swift", "SavedIdentificationCompatibilityTests.swift", "IdentificationBenchmarkTests.swift", "ProductionDescriptionSearchTests.swift", "DescriptionSearchArchitectureTests.swift", "SemanticSearchTests.swift", "SemanticEndToEndTests.swift", "TropicalPacificCatalogueTests.swift", "LocalObservationParserTests.swift", "TestResources.swift", "CatalogTestDoubles.swift", "SelectedPackStateTests.swift", "AppCopyTests.swift", "GlobalCatalogueSchemaTests.swift", "GlobalDraftCatalogueTests.swift", "GlobalPackTests.swift", "GlobalSubregionTests.swift", "GlobalPackEvaluationTests.swift", "GlobalPackPerformanceTests.swift", "RecordReviewMethodTests.swift", "CatalogueAttributionTests.swift", "SpeciesCatalogueTests.swift", "DiverFeedbackTests.swift", "FieldGuideTests.swift", "DiveLogTests.swift", "DefaultDiveRegionTests.swift", "GlobalEvidenceTests.swift", "SizeEvidenceTests.swift", "SearchGoldenOrderingTests.swift", "PackListingTests.swift", "RankingNameAndVariantTests.swift", "SearchIndexStoreTests.swift", "BuildChannelTests.swift", "FirstUsePerformanceTests.swift", "InternalInstrumentationTests.swift"],
            resources: [.copy("Fixtures")]
        )
    ]
)
