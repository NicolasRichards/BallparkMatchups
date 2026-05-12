import SwiftUI

struct DebugOverlayView: View {
    let info: GameViewModel.DebugInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DEBUG")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.green)

            row("Poll interval", "\(Int(info.pollingInterval))s")
            row("Last response", info.lastResponseTime.map { formatTime($0) } ?? "—")
            row("Request count", "\(info.requestCount)")
            row("Candidates", "\(info.candidateSplits)")
            row("Shown splits", "\(info.shownSplits)")
            row("Last refresh", info.lastRefreshKind)
        }
        .padding(12)
        .background(Color.black.opacity(0.85))
        .overlay(
            Rectangle()
                .stroke(Color.green.opacity(0.5), lineWidth: 1)
        )
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.top, 110)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label + ":")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color.green.opacity(0.7))
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.green)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
