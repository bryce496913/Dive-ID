import Observation
import PhotosUI
import SwiftUI

enum PhotoSelectionError: Equatable {
    case unableToRead, unsupportedFormat, decodingFailed, processingFailed, sessionLimitReached

    var message: String {
        switch self {
        case .sessionLimitReached: AppCopy.sessionCapacityReached
        case .unableToRead: "The selected item could not be read. Please choose another photo."
        case .unsupportedFormat: "That image format is not supported. Please choose a JPEG, PNG, or HEIF photo."
        case .decodingFailed: "The selected image could not be decoded. Please choose another photo."
        case .processingFailed: "The photo could not be prepared for identification. Please try another photo."
        }
    }
}

@MainActor @Observable
final class PhotoIdentificationViewModel {
    private(set) var processedPhoto: ProcessedPhoto?
    private(set) var isLoadingSelection = false
    private(set) var isCreatingSession = false
    var selectionError: PhotoSelectionError?
    /// Optional "anything else you noticed". Searched with the existing description ranker.
    var notesText = ""
    private(set) var packState: SelectedPackState = .notLoaded
    private let sessionStore: any IdentificationSessionStore
    private let photoProcessor: any PhotoProcessingService
    private let packLoader: SelectedPackLoader?
    /// Records the search for "Was this right?". Never the photo itself.
    private let feedback: DiverFeedbackService?
    private var selectionTask: Task<Void, Never>?
    private var generation = 0

    init(sessionStore: any IdentificationSessionStore, photoProcessor: any PhotoProcessingService,
         packLoader: SelectedPackLoader? = nil, feedback: DiverFeedbackService? = nil) {
        self.sessionStore = sessionStore
        self.photoProcessor = photoProcessor
        self.packLoader = packLoader
        self.feedback = feedback
    }

    /// Loads the selected dive region, which the photo is matched in.
    func load() async {
        guard let packLoader else { return }
        packState = await packLoader.load()
    }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }

    var canSubmit: Bool { processedPhoto != nil && !isLoadingSelection && !isCreatingSession }

    @discardableResult
    func selectPhoto(loadData: @escaping @Sendable () async throws -> Data) -> Task<Void, Never> {
        selectionTask?.cancel()
        generation += 1
        let currentGeneration = generation
        processedPhoto = nil
        selectionError = nil
        isLoadingSelection = true
        let task = Task {
            do {
                let data = try await loadData()
                try Task.checkCancellation()
                let photo = try await photoProcessor.processPhotoData(data)
                try Task.checkCancellation()
                guard currentGeneration == generation else { return }
                processedPhoto = photo
                selectionError = nil
                isLoadingSelection = false
            } catch is CancellationError {
                if currentGeneration == generation { isLoadingSelection = false }
            } catch let error as PhotoProcessingError {
                guard currentGeneration == generation else { return }
                processedPhoto = nil
                selectionError = error == .unsupportedFormat ? .unsupportedFormat : (error == .decodingFailed ? .decodingFailed : .processingFailed)
                isLoadingSelection = false
            } catch {
                guard currentGeneration == generation else { return }
                processedPhoto = nil
                selectionError = .unableToRead
                isLoadingSelection = false
            }
        }
        selectionTask = task
        return task
    }

    func cancelSelection() {
        selectionTask?.cancel()
        generation += 1
        isLoadingSelection = false
    }

    func submit() async -> UUID? {
        guard let processedPhoto, canSubmit else { return nil }
        isCreatingSession = true
        defer { isCreatingSession = false }
        do {
            let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = IdentificationRequest(source: .processedPhoto(processedPhoto.reference),
                                                context: IdentificationContext(region: pack?.id, additionalDescription: notes.isEmpty ? nil : notes))
            let sessionID = try await sessionStore.createSession(for: request, photo: processedPhoto)
            if let pack { feedback?.beginAttempt(sessionID: sessionID, rawDescription: notesText, pack: pack, previous: nil, source: .photo) }
            return sessionID
        } catch IdentificationSessionStoreError.capacityReached {
            selectionError = .sessionLimitReached
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            selectionError = .processingFailed
            return nil
        }
    }
}

struct PhotoIdentificationView: View {
    @State var viewModel: PhotoIdentificationViewModel
    @State private var pickerItem: PhotosPickerItem?
    let router: AppRouter

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Choose a clear photo of one marine animal. It stays on this device and is never uploaded.")
                    .foregroundStyle(Color.appTextSecondary)
                if let pack = viewModel.pack {
                    Text("Dive region: \(pack.displayName)").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                preview
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose From Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .onChange(of: pickerItem) { _, item in
                    guard let item else { viewModel.cancelSelection(); return }
                    viewModel.selectPhoto {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        return data
                    }
                }
#if DEBUG
                // UI tests can't drive the system photo picker reliably, so they use a generated photo.
                if ProcessInfo.processInfo.arguments.contains("-uiTestingSamplePhoto") {
                    Button("Use Test Photo") { viewModel.selectPhoto { Self.testPhotoData() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("useTestPhoto")
                }
#endif
                Button("Take Photo (coming later)", systemImage: "camera") {}.buttonStyle(.bordered).disabled(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Anything else you noticed? (optional)").font(.subheadline.weight(.semibold))
                    TextField("For example: about 30 cm, seen at night on a wreck", text: $viewModel.notesText, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("photoNotes")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .appCard()
                Text("Development builds only. Photo matching uses a test recognizer, so results are placeholders.")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                if let error = viewModel.selectionError { Text(error.message).foregroundStyle(Color.appError) }
                PrimaryActionButton(title: "Identify Photo", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
                    Task {
                        await router.waitForSessionUpdates()
                        if let sessionID = await viewModel.submit() {
                            router.navigate(to: .identificationResults(sessionID: sessionID))
                        }
                    }
                }
                .accessibilityIdentifier("identifyPhoto")
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle("Identify From Photo")
        .task { await viewModel.load() }
    }

#if DEBUG
    /// A plain 64 × 64 PNG, made on the device.
    nonisolated private static func testPhotoData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
#endif

    @ViewBuilder private var preview: some View {
        Group {
            if viewModel.isLoadingSelection {
                ProgressView("Preparing photo…").accessibilityIdentifier("photoLoading")
            } else if let data = viewModel.processedPhoto?.previewData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 50))
                    Text("No photo selected")
                }
                .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .appCard()
    }
}
