import SwiftUI

struct DebugOverlayView: View {
    let info: GameViewModel.DebugInfo
    /// Flipping the flag needs a fresh game session to take effect, so this
    /// reports the stored value rather than the one the running view model read.
    @State private var pushFlag = FeatureFlags.pushFeedEnabled

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

            Divider()
                .overlay(Color.green.opacity(0.4))
                .padding(.vertical, 2)

            // A bare HStack of Text only hit-tests on the glyphs, so tapping
            // the gaps did nothing. Fill the panel width, give it a real
            // contentShape, and make it look like something you press.
            Button {
                pushFlag.toggle()
                FeatureFlags.pushFeedEnabled = pushFlag
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PUSH FEED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(pushFlag ? .black : Color.green.opacity(0.8))
                    Text(pushFlag ? "ON — reopen game" : "OFF — TAP HERE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(pushFlag ? .black : .green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(pushFlag ? Color.green : Color.green.opacity(0.12))
                .overlay(Rectangle().stroke(Color.green, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let push = info.push {
                row("Push active", info.pushEnabled ? "yes" : "no")
                row("Socket", push.isConnected ? "connected" : "down")
                if let note = push.socketNote, !push.isConnected {
                    Text(note)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                row("Patched", "\(push.updatesApplied)")
                row("Full refresh", "\(push.fullRefreshes)")
                row("Patch fails", "\(push.patchFailures)")
                row("Push KB", "\(push.bytesOverPush / 1024)")
                row("Poll KB est", "\(push.estimatedPollingBytes / 1024)")
                if let err = push.lastError {
                    row("Last error", String(err.prefix(24)))
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.85))
        .overlay(
            Rectangle()
                .stroke(Color.green.opacity(0.5), lineWidth: 1)
        )
        .frame(maxWidth: 240, alignment: .leading)
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
