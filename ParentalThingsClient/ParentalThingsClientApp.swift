import SwiftUI

@main
struct ParentalThingsClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusView(poller: appDelegate.poller)
        } label: {
            MenuBarLabel(poller: appDelegate.poller)
        }
        .menuBarExtraStyle(.window)

        Window("ParentalThings Client — Configuration", id: "configuration") {
            ConfigurationView(poller: appDelegate.poller)
        }
        .defaultSize(width: 480, height: 520)
        .windowResizability(.contentSize)

        Window("ParentalThings Client — Logs", id: "logs") {
            LogView(poller: appDelegate.poller)
        }
        .defaultSize(width: 600, height: 400)
    }
}

private struct MenuBarLabel: View {
    let poller: Poller
    @Environment(\.openWindow) private var openWindow
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("apiKey") private var apiKey = ""

    var body: some View {
        Group {
            if poller.unreviewedCount > 0 {
                Label("\(poller.unreviewedCount)", image: "MenuBarIcon")
            } else {
                Image("MenuBarIcon")
            }
        }
        .onAppear {
            if serverURL.isEmpty || apiKey.isEmpty {
                openWindow(id: "configuration")
            }
        }
    }
}
