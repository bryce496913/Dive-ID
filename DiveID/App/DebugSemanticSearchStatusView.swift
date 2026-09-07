#if DEBUG
import SwiftUI

/// A deliberately small developer-only proof of semantic execution (or fallback).
struct DebugSemanticSearchStatusView: View {
    let selection: DescriptionRetrievalEngine
    let reporter: DebugSemanticDiagnosticsReporter
    @State private var latest: SemanticRetrievalMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Semantic search diagnostics").font(.caption.bold())
            Text("Requested engine: \(name(latest?.requestedEngine ?? selection))")
            Text("Actual engine: \(latest.map { name($0.actualEngine) } ?? "Not run")")
            if let reason = latest?.fallbackReason { Text("Fallback: \(reason.description)") }
        }
        .font(.caption2.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.black.opacity(0.9))
        .foregroundStyle(.white)
        .accessibilityIdentifier("semanticSearchDiagnostics")
        .task {
            latest = await reporter.latest
            for await metrics in reporter.updates { latest = metrics }
        }
    }

    private func name(_ engine: DescriptionRetrievalEngine) -> String {
        switch engine {
        case .experimentalCoreML: "Core ML semantic"
        case .productionBM25: latest?.requestedEngine == .experimentalCoreML ? "BM25 fallback" : "BM25"
        }
    }
}
#endif
