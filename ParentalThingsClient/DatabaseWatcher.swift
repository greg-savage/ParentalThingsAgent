import Foundation
import os

private let logger = Logger(subsystem: "com.parentalthings.client", category: "watcher")

final class DatabaseWatcher: Sendable {

    let path: String
    private let fallbackInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.parentalthings.watcher")

    private let continuation: AsyncStream<Void>.Continuation
    let events: AsyncStream<Void>

    private class State: @unchecked Sendable {
        var fd: Int32 = -1
        var fileSource: DispatchSourceFileSystemObject?
        var timerSource: DispatchSourceTimer?
        var debounceWork: DispatchWorkItem?
    }
    private let state = State()

    init(path: String) {
        self.path = path
        var captured: AsyncStream<Void>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func start() {
        queue.async { [self] in
            startTimer()
            openAndWatch()
        }
    }

    func stop() {
        queue.async { [self] in
            state.debounceWork?.cancel()
            state.fileSource?.cancel()
            state.fileSource = nil
            state.timerSource?.cancel()
            state.timerSource = nil
            if state.fd >= 0 {
                close(state.fd)
                state.fd = -1
            }
            continuation.finish()
        }
    }

    // MARK: - Private (all called on `queue`)

    private func openAndWatch() {
        let fd = Darwin.open(path, O_EVTONLY)
        if fd < 0 {
            logger.warning("Cannot open \(self.path) for watching (errno \(errno)) — relying on fallback timer")
            return
        }
        state.fd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [self] in
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                logger.info("chat.db was replaced — reopening watcher")
                state.fileSource?.cancel()  // setCancelHandler will close the fd
                state.fileSource = nil
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    openAndWatch()
                }
                emitDebounced()
                return
            }
            emitDebounced()
        }

        source.setCancelHandler { [self] in
            if state.fd >= 0 {
                Darwin.close(state.fd)
                state.fd = -1
            }
        }

        state.fileSource = source
        source.resume()
        logger.info("Watching \(self.path) for changes")
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        timer.setEventHandler { [self] in
            logger.debug("Fallback timer fired")
            continuation.yield()
        }
        state.timerSource = timer
        timer.resume()
    }

    private func emitDebounced() {
        state.debounceWork?.cancel()
        let work = DispatchWorkItem { [self] in
            continuation.yield()
        }
        state.debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
