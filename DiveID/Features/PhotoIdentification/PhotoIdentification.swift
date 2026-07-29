import Observation
import PhotosUI
import SwiftUI

@MainActor @Observable final class PhotoIdentificationViewModel {
    var imageData: Data?; var isLoading = false; var errorMessage: String?
    private let service: any MarineLifeIdentificationService
    init(service: any MarineLifeIdentificationService) { self.service = service }
    func load(_ item: PhotosPickerItem?) async { imageData = try? await item?.loadTransferable(type: Data.self) }
    func submit() async -> Bool { guard let imageData else { return false }; isLoading = true; defer { isLoading = false }; do { _ = try await service.identify(from: imageData); return true } catch is CancellationError { return false } catch { errorMessage = "The selected photo could not be processed for this demo."; return false } }
}

struct PhotoIdentificationView: View {
    @State var viewModel: PhotoIdentificationViewModel; @State private var pickerItem: PhotosPickerItem?; let router: AppRouter
    var body: some View { ScrollView { VStack(spacing: 18) { Text("Choose a clear photo of one marine animal. It stays on this device for the current session.").foregroundStyle(.secondary); Group { if let data = viewModel.imageData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else { VStack(spacing: 12) { Image(systemName: "photo.badge.plus").font(.system(size: 50)); Text("No photo selected") }.foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, minHeight: 260).background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)); PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose From Library", systemImage: "photo.on.rectangle") }.buttonStyle(.bordered).onChange(of: pickerItem) { _, item in Task { await viewModel.load(item) } }; Button("Take Photo (coming later)", systemImage: "camera") {}.buttonStyle(.bordered).disabled(true); Text("Demo identification uses local mock results; no image is uploaded.").font(.footnote).foregroundStyle(.secondary); PrimaryActionButton(title: "Identify Photo", isLoading: viewModel.isLoading, disabled: viewModel.imageData == nil) { Task { if await viewModel.submit() { router.navigate(to: .identificationResults(.photo)) } } }.accessibilityIdentifier("identifyPhoto") }.padding() }.background(Color.appBackground).navigationTitle("Identify From Photo") }
}
#Preview { NavigationStack { PhotoIdentificationView(viewModel: .init(service: MockMarineLifeIdentificationService(delay: .zero)), router: AppRouter()) } }
