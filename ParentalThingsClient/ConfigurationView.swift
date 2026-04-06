import SwiftUI

struct ConfigurationView: View {
    let poller: Poller

    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("backfillDays") private var backfillDays = 7

    @State private var statusMessage = ""
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL, prompt: Text("http://192.168.1.x:3000"))
                    .disableAutocorrection(true)
                SecureField("API Key", text: $apiKey, prompt: Text("Child API key from server"))
                    .disableAutocorrection(true)
            } header: {
                Text("Server Connection")
            } footer: {
                Text("Enter the server's local IP and a child API key (from Configure > Children on the dashboard).")
            }

            Section("Settings") {
                Stepper("Backfill days: \(backfillDays)", value: $backfillDays, in: 1...30)
            }

            Section {
                HStack {
                    Button("Apply & Restart") {
                        poller.startIfConfigured()
                        statusMessage = poller.isRunning ? "Poller restarted" : "Not configured — enter server URL and API key"
                        statusIsError = !poller.isRunning
                    }
                    .disabled(serverURL.isEmpty || apiKey.isEmpty)

                    if poller.isRunning {
                        Button("Stop") {
                            poller.stop()
                            statusMessage = "Poller stopped"
                            statusIsError = false
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(statusIsError ? .orange : .green)
                        .font(.subheadline)
                }
            }

            Section("Status") {
                LabeledContent("Running", value: poller.isRunning ? "Yes" : "No")
                LabeledContent("iMessage DB", value: poller.dbConnected ? "Connected" : "Not connected")
                LabeledContent("Contacts", value: poller.contactsStatus)
                if let lastPoll = poller.lastPollTime {
                    LabeledContent("Last poll", value: lastPoll.formatted(.relative(presentation: .named)))
                }
                LabeledContent("Processed", value: "\(poller.totalProcessed)")
                LabeledContent("Flagged", value: "\(poller.totalFlagged)")
                if let error = poller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
    }
}
