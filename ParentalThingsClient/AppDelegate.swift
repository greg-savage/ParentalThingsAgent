import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {
    let poller = Poller()
    // Kept alive so the browse persists; macOS Local Network permission requires
    // an active Bonjour browse to reapply on each launch.
    private var localNetworkBrowser: NWBrowser?

    func applicationDidFinishLaunching(_ notification: Notification) {
        triggerLocalNetworkPermission()
        poller.startIfConfigured()
    }

    private func triggerLocalNetworkPermission() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: params)
        browser.stateUpdateHandler = { _ in }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: .main)
        localNetworkBrowser = browser
    }
}
