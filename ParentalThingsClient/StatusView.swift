import SwiftUI

struct StatusView: View {
    let poller: Poller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("ParentalThings Client")
                    .font(.headline)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Stats
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("iMessage DB").font(.caption).foregroundStyle(.secondary)
                    Text(poller.dbConnected ? "Connected" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(poller.dbConnected ? .green : .orange)
                }
                GridRow {
                    Text("Contacts").font(.caption).foregroundStyle(.secondary)
                    Text(poller.contactsStatus).font(.caption)
                        .foregroundStyle(poller.contactsStatus.contains("Not") ? .orange : .green)
                }
                GridRow {
                    Text("Last check").font(.caption).foregroundStyle(.secondary)
                    Text(lastPollText).font(.caption)
                }
                GridRow {
                    Text("Processed").font(.caption).foregroundStyle(.secondary)
                    Text("\(poller.totalProcessed)").font(.caption)
                }
                GridRow {
                    Text("Flagged").font(.caption).foregroundStyle(.secondary)
                    Text("\(poller.totalFlagged)").font(.caption.bold())
                        .foregroundStyle(poller.totalFlagged > 0 ? .red : .primary)
                }
            }

            // Error
            if let error = poller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
            }

            // Recent flagged messages
            if !poller.recentFlagged.isEmpty {
                Divider()

                HStack {
                    Text("Unreviewed")
                        .font(.caption.bold())
                    Spacer()
                    if poller.unreviewedCount > 0 {
                        Text("\(poller.unreviewedCount)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                    }
                }

                ForEach(poller.recentFlagged) { msg in
                    HStack(alignment: .top, spacing: 6) {
                        Text(msg.severity.prefix(1).uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(severityColor(msg.severity), in: RoundedRectangle(cornerRadius: 3))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(msg.sender)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text(msg.messageText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Button {
                            Task { await poller.markReviewed(messageId: msg.id) }
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Mark Reviewed")
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Configuration…") {
                    openWindow(id: "configuration")
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("View Logs…") {
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.link)
        }
        .padding()
        .frame(width: 280)
    }

    private var statusColor: Color {
        if !poller.isRunning { return .gray }
        if poller.lastError != nil { return .orange }
        return .green
    }

    private var statusLabel: String {
        if !poller.isRunning { return "Stopped" }
        if poller.isPolling { return "Checking…" }
        if poller.lastError != nil { return "Error" }
        return "Running"
    }

    private var lastPollText: String {
        guard let t = poller.lastPollTime else { return "Never" }
        return t.formatted(.relative(presentation: .named))
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "critical": return .red
        case "high": return .orange
        case "medium": return .yellow
        default: return .green
        }
    }
}
