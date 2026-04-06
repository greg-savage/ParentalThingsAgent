import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let poller = Poller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        poller.startIfConfigured()
    }
}
