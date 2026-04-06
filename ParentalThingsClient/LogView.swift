import SwiftUI

struct LogView: View {
    let poller: Poller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    poller.clearLogs()
                }
                .buttonStyle(.link)
            }
            .padding()

            Divider()

            if poller.logEntries.isEmpty {
                Text("No log entries yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(poller.logEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(colorForLevel(entry.level))
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.date.formatted(.dateTime.hour().minute().second()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .id(entry.id)
                    }
                    .onChange(of: poller.logEntries.count) {
                        if let last = poller.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
    }

    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .info:    return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
