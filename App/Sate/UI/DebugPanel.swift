import SwiftUI

/// The last request's `NetworkTrace`, shown only when `settings.showDebugPanel`.
///
/// `cf-aig-log-id` is the handle for finding the request in Cloudflare's log
/// viewer; `cf-ray` is what edge errors (52x) carry instead. Both are tappable so
/// they can be pasted into the dashboard.
///
/// The API token is never part of `NetworkTrace` and is never rendered here.
struct DebugPanel: View {
    let trace: NetworkTrace
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    DebugRow(label: row.label, value: row.value)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ladybug")
                Text("Debug")
                Spacer()
                if let status = trace.statusCode {
                    Text("\(status)")
                        .monospacedDigit()
                        .foregroundStyle(status < 400 ? .secondary : Color.red)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Chrome, not content: it floats in the bottom inset above the
        // transcript, inside `ChatView`'s `GlassEffectContainer`.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var rows: [Row] {
        var rows: [Row] = [
            Row(label: "route", value: trace.route.isEmpty ? "—" : trace.route),
            Row(label: "model", value: trace.model.isEmpty ? "—" : trace.model),
            Row(label: "status", value: trace.statusCode.map(String.init) ?? "—"),
            Row(label: "cf-aig-log-id", value: trace.logID ?? "—"),
            Row(label: "cf-ray", value: trace.ray ?? "—"),
            Row(label: "cache", value: trace.cacheStatus ?? "—"),
            // step > 0 means a fallback node in a dynamic route served this.
            Row(label: "step", value: trace.step.map(String.init) ?? "—"),
            Row(label: "ttfb", value: format(trace.timeToFirstByte)),
            Row(label: "duration", value: format(trace.duration)),
            Row(label: "bytes", value: "\(trace.bytesReceived)"),
            Row(label: "retried", value: trace.retried ? "yes" : "no")
        ]
        if (trace.step ?? 0) > 0 {
            rows.append(Row(label: "note", value: "served by fallback"))
        }
        return rows
    }

    private func format(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        return interval < 1
            ? "\(Int((interval * 1000).rounded())) ms"
            : String(format: "%.2f s", interval)
    }
}

private struct DebugRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption2, design: .monospaced))
    }
}
