import AVFoundation
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

/// Whether "Take Photo" can open the camera.
enum CameraAvailability: Equatable {
    case available, notDetermined, denied, noCamera

    static func current() -> CameraAvailability {
#if DEBUG
        // UI tests check the denied state with -uiTestingCameraDenied (the simulator has no camera).
        if ProcessInfo.processInfo.arguments.contains("-uiTestingCameraDenied") { return .denied }
#endif
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .available
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    var message: String? {
        switch self {
        case .denied: "Camera access is off for Dive ID. You can turn it on in Settings, or choose a photo from your library."
        case .noCamera: "This device has no camera available. Choose a photo from your library."
        case .available, .notDetermined: nil
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
    /// The part of the photo sent to the recognizer; the whole photo unless the diver (or the
    /// suggestion) narrows it.
    var cropRegion: PhotoCropRegion = .full
    /// Vision's suggested box around the subject, when it found one.
    private(set) var suggestedRegion: PhotoCropRegion?
    /// Internal experiment: underwater colour correction before recognition (off by default).
    var colourCorrection = false
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
        suggestedRegion = nil
        cropRegion = .full
        selectionError = nil
        isLoadingSelection = true
        let task = Task {
            do {
                let data = try await loadData()
                try Task.checkCancellation()
                let photo = try await photoProcessor.processPhotoData(data)
                try Task.checkCancellation()
                // Saliency runs off the main thread; no suggestion just means the whole photo.
                let suggestion = await Task.detached(priority: .userInitiated) { PhotoImageTools.suggestedRegion(photo.uploadData) }.value
                try Task.checkCancellation()
                guard currentGeneration == generation else { return }
                processedPhoto = photo
                suggestedRegion = suggestion
                cropRegion = suggestion ?? .full
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

    func useWholePhoto() { cropRegion = .full }
    func useSuggestedRegion() { if let suggestedRegion { cropRegion = suggestedRegion } }

    func submit() async -> UUID? {
        guard let processedPhoto, canSubmit else { return nil }
        isCreatingSession = true
        defer { isCreatingSession = false }
        do {
            let region = cropRegion, corrected = colourCorrection
            // The recognizer gets the cropped region (re-encoded, so still without metadata);
            // the preview stays the full photo.
            let prepared = try await Task.detached(priority: .userInitiated) {
                try processedPhoto.preparedForRecognition(region: region, colourCorrected: corrected)
            }.value
            let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = IdentificationRequest(source: .processedPhoto(prepared.reference),
                                                context: IdentificationContext(region: pack?.id, additionalDescription: notes.isEmpty ? nil : notes))
            let sessionID = try await sessionStore.createSession(for: request, photo: prepared)
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
    @State private var showsCamera = false
    @State private var camera = CameraAvailability.current()
#if DEBUG || DIVEID_INTERNAL
    @AppStorage(UnderwaterColourCorrection.settingKey) private var colourCorrection = false
#endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    let router: AppRouter

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Choose or take a clear photo of one marine animal. It stays on this device and is never uploaded.")
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let pack = viewModel.pack {
                    Text("Dive region: \(pack.displayName)").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                PhotoGuidance()
                preview
                sourceButtons
                if let message = camera.message {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Label(message, systemImage: "camera.badge.ellipsis").foregroundStyle(Color.appTextSecondary)
                        if camera == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                            Button("Open Settings") { openURL(settings) }.accessibilityIdentifier("openCameraSettings")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cameraUnavailable")
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Anything else you noticed? (optional)").font(.subheadline.weight(.semibold))
                    TextField("For example: about 30 cm, seen at night on a wreck", text: $viewModel.notesText, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("photoNotes")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .appCard()
#if DEBUG || DIVEID_INTERNAL
                Toggle("Experimental: underwater colour correction", isOn: $colourCorrection)
                    .font(.footnote)
                    .accessibilityIdentifier("colourCorrectionToggle")
#endif
                Text("Development builds only. Your photo is compared with the reference photos bundled in the app; species without one can't be matched from a photo.")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                if let error = viewModel.selectionError { Text(error.message).foregroundStyle(Color.appError) }
                PrimaryActionButton(title: "Identify Photo", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
                    Task {
#if DEBUG || DIVEID_INTERNAL
                        viewModel.colourCorrection = colourCorrection
#endif
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
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                showsCamera = false
                guard let image, let data = image.jpegData(compressionQuality: 0.95) else { return }
                // Processing re-encodes the photo, so camera metadata (including location) is dropped.
                viewModel.selectPhoto { data }
            }
            .ignoresSafeArea()
        }
    }

    /// Library and camera, side by side, or stacked at accessibility text sizes.
    @ViewBuilder private var sourceButtons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: AppTheme.Spacing.s)) : AnyLayout(HStackLayout(spacing: AppTheme.Spacing.s))
        layout {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose From Library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("chooseFromLibrary")
            .onChange(of: pickerItem) { _, item in
                guard let item else { viewModel.cancelSelection(); return }
                viewModel.selectPhoto {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return data
                }
            }
            Button { takePhoto() } label: {
                Label("Take Photo", systemImage: "camera").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("takePhoto")
        }
#if DEBUG
        // UI tests can't drive the system photo picker reliably, so they use a generated photo.
        if ProcessInfo.processInfo.arguments.contains("-uiTestingSamplePhoto") {
            Button("Use Test Photo") { viewModel.selectPhoto { Self.testPhotoData() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("useTestPhoto")
        }
#endif
    }

    private func takePhoto() {
        camera = CameraAvailability.current()
        switch camera {
        case .available: showsCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                camera = granted ? .available : .denied
                showsCamera = granted
            }
        case .denied, .noCamera: break  // the explanation shows; the library still works
        }
    }

#if DEBUG
    /// A 320 × 240 PNG with an orange "animal" on blue water, made on the device.
    nonisolated private static func testPhotoData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).pngData { context in
            UIColor(red: 0.05, green: 0.25, blue: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            UIColor.systemOrange.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 170, y: 70, width: 110, height: 70))
        }
    }
#endif

    @ViewBuilder private var preview: some View {
        Group {
            if viewModel.isLoadingSelection {
                ProgressView("Preparing photo…").accessibilityIdentifier("photoLoading")
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if let data = viewModel.processedPhoto?.previewData, let image = UIImage(data: data) {
                PhotoCropEditor(image: image, region: $viewModel.cropRegion, hasSuggestion: viewModel.suggestedRegion != nil,
                                useWholePhoto: viewModel.useWholePhoto, useSuggestion: viewModel.useSuggestedRegion)
            } else {
                VStack(spacing: AppTheme.Spacing.m) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 50))
                    Text("No photo selected")
                }
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .appCard()
    }
}

/// Short advice on photos the recognizer can use.
private struct PhotoGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("For the best match").font(.subheadline.weight(.semibold))
            ForEach(["One animal in the photo", "Side view if you can", "Fill the frame with the animal", "Get closer rather than zooming in"], id: \.self) { tip in
                Label(tip, systemImage: "checkmark.circle").labelStyle(CompactLabelStyle()).font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoGuidance")
    }
}

/// The photo with a box the diver drags around one animal. Corners resize it; dragging inside
/// moves it. VoiceOver users get the box's size and a "Use Whole Photo" button.
struct PhotoCropEditor: View {
    let image: UIImage
    @Binding var region: PhotoCropRegion
    let hasSuggestion: Bool
    let useWholePhoto: () -> Void
    let useSuggestion: () -> Void
    @State private var dragStart: PhotoCropRegion?

    private enum Handle: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(region.isFull ? "Using the whole photo. Drag a corner to box one animal." : "Drag the box around one animal.")
                .font(.footnote).foregroundStyle(Color.appTextSecondary)
            GeometryReader { geometry in
                let frame = fittedFrame(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    let box = CGRect(x: frame.minX + region.x * frame.width, y: frame.minY + region.y * frame.height,
                                     width: region.width * frame.width, height: region.height * frame.height)
                    // Dim everything outside the box.
                    Path { path in path.addRect(frame); path.addRect(box) }
                        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    Rectangle().strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: box.width, height: box.height)
                        .contentShape(Rectangle())
                        .offset(x: box.minX, y: box.minY)
                        .gesture(DragGesture().onChanged { value in move(by: value.translation, in: frame) }.onEnded { _ in dragStart = nil })
                    ForEach(Handle.allCases, id: \.self) { handle in
                        Circle().fill(Color.white).frame(width: 24, height: 24)
                            .contentShape(Rectangle().size(width: 44, height: 44).offset(x: -10, y: -10))
                            .offset(x: (handle == .topLeft || handle == .bottomLeft ? box.minX : box.maxX) - 12,
                                    y: (handle == .topLeft || handle == .topRight ? box.minY : box.maxY) - 12)
                            .gesture(DragGesture().onChanged { value in resize(handle, by: value.translation, in: frame) }.onEnded { _ in dragStart = nil })
                    }
                }
            }
            .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo crop box")
            .accessibilityValue(region.isFull ? "Whole photo" : "Covers \(Int((region.area * 100).rounded())) percent of the photo")
            .accessibilityIdentifier("cropEditor")
            HStack(spacing: AppTheme.Spacing.s) {
                Button("Use Whole Photo", action: useWholePhoto)
                    .disabled(region.isFull)
                    .accessibilityIdentifier("useWholePhoto")
                if hasSuggestion {
                    Button("Suggested Box", action: useSuggestion).accessibilityIdentifier("useSuggestedCrop")
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
        .padding(AppTheme.Spacing.s)
    }

    /// Where the aspect-fitted photo sits in the available space.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let scale = min(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func move(by translation: CGSize, in frame: CGRect) {
        let start = dragStart ?? region
        dragStart = start
        region = PhotoCropRegion(x: start.x + translation.width / frame.width, y: start.y + translation.height / frame.height,
                                 width: start.width, height: start.height).clamped()
    }

    private func resize(_ handle: Handle, by translation: CGSize, in frame: CGRect) {
        let start = dragStart ?? region
        dragStart = start
        let dx = translation.width / frame.width, dy = translation.height / frame.height
        var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
        switch handle {
        case .topLeft: left += dx; top += dy
        case .topRight: right += dx; top += dy
        case .bottomLeft: left += dx; bottom += dy
        case .bottomRight: right += dx; bottom += dy
        }
        let minimum = PhotoCropRegion.minimumSide
        left = min(max(left, 0), right - minimum); top = min(max(top, 0), bottom - minimum)
        right = max(min(right, 1), left + minimum); bottom = max(min(bottom, 1), top + minimum)
        region = PhotoCropRegion(x: left, y: top, width: right - left, height: bottom - top).clamped()
    }
}

/// The system camera. Returns nil when the diver cancels.
private struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}
