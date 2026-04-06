import SwiftUI

@main
struct ParentalThingsClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusView(poller: appDelegate.poller)
        } label: {
            let count = appDelegate.poller.unreviewedCount
            if count > 0 {
                Label("\(count)", image: "MenuBarIcon")
            } else {
                Image("MenuBarIcon")
            }
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
