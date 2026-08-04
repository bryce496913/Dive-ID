import Observation
import PhotosUI
import SwiftUI

enum PhotoSelectionError: Equatable {
    case unableToRead, unsupportedFormat, decodingFailed, processingFailed

    var message: String {
        switch self {
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
    private let sessionStore: any IdentificationSessionStore
    private let photoProcessor: any PhotoProcessingService
    private var selectionTask: Task<Void, Never>?
    private var generation = 0

    init(sessionStore: any IdentificationSessionStore, photoProcessor: any PhotoProcessingService) {
        self.sessionStore = sessionStore
        self.photoProcessor = photoProcessor
    }

    var canSubmit: Bool { processedPhoto != nil && !isLoadingSelection && !isCreatingSession }

    func selectPhoto(loadData: @escaping @Sendable () async throws -> Data) {
        selectionTask?.cancel()
        generation += 1
        let currentGeneration = generation
        processedPhoto = nil
        selectionError = nil
        isLoadingSelection = true
        selectionTask = Task {
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
            let request = IdentificationRequest(source: .processedPhoto(processedPhoto.reference))
            return try await sessionStore.createSession(for: request, photo: processedPhoto)
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
                Text("Choose a clear photo of one marine animal. It stays on this device for the current session.")
                    .foregroundStyle(Color.appTextSecondary)
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
                Button("Take Photo (coming later)", systemImage: "camera") {}.buttonStyle(.bordered).disabled(true)
                Text("Demo identification uses local mock results; no image is uploaded.")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                if let error = viewModel.selectionError { Text(error.message).foregroundStyle(Color.appError) }
                PrimaryActionButton(title: "Identify Photo", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
                    Task {
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
    }

    @ViewBuilder private var preview: some View {
        Group {
            if viewModel.isLoadingSelection {
                ProgressView("Preparing photo…").accessibilityIdentifier("photoLoading")
            } else if let data = viewModel.processedPhoto?.previewData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 50))
                    Text("No photo selected")
                }
                .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}
