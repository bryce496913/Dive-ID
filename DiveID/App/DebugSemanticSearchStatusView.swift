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
            Text("Requested engine: \(requested(latest?.requestedEngine ?? selection))")
            Text("Actual engine: \(latest.map(actual) ?? "Not run")")
            if latest?.fallbackOutcome == .nothingAboveCutoff { Text("Semantic fallback: nothing above the cutoff") }
            if let reason = latest?.fallbackReason { Text("Semantic unavailable: \(reason.description)") }
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

    private func requested(_ engine: DescriptionRetrievalEngine) -> String {
        switch engine {
        case .experimentalCoreML: "BM25, semantic fallback"
        case .productionBM25: "BM25"
        }
    }

    private func actual(_ metrics: SemanticRetrievalMetrics) -> String {
        metrics.fallbackOutcome == .served ? "Semantic fallback (BM25 found nothing)" : "BM25"
    }
}
#endif
