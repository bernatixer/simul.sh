import AppKit
import Foundation
import SwiftUI

/// Lets an agent drive a test copy without screen-recording or accessibility
/// permissions: with `SIMUL_DEV_HOOKS=1`, SIGUSR1 runs the commands in
/// `<data dir>/devcmd` (one per line) and appends results to `<data dir>/devlog`.
///   select <title>   select the session with that title
///   review           toggle the selected session's review
///   snap <name>      save the main window as <data dir>/<name>.png
///   scroll <steps>   scroll the review by 80 pt per step (negative: up), logging ms per step
///   top              scroll the review back to its top
///   size <w> <h>     resize the main window
///   pr <owner/repo> <n>  review that pull request in the selected session
///   folder <path>    review that folder in the selected session (a PR's worktree when
///                    fetching can't run, e.g. a locked screen's SSH agent refuses)
///   base <ref>       compare against that ref
///   window           host the app in a window of its own when none shows (a locked
///                    screen opens no SwiftUI windows), starting the model once
/// ponytail: dev-only signal hook, no UI; replace with UI tests if we ever get Xcode.
@MainActor
enum DevHooks {
    private static var source: DispatchSourceSignal?
    private static var window: NSWindow?

    static func install(model: AppModel) {
        guard ProcessInfo.processInfo.environment["SIMUL_DEV_HOOKS"] == "1", source == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { Task { await run(model: model) } } }
        s.resume()
        source = s
    }

    private static func run(model: AppModel) async {
        let dir = Paths.applicationSupport
        let commands = (try? String(contentsOf: dir.appendingPathComponent("devcmd"), encoding: .utf8)) ?? ""
        // Timings shouldn't depend on whether the copy is in front: no App Nap meanwhile.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "dev hooks")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        for line in commands.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let verb = words.first else { continue }
            let rest = words.dropFirst().joined(separator: " ")
            switch verb {
            case "select":
                if let session = model.sessions.first(where: { $0.title == rest }) { model.selectedSessionID = session.id }
            case "review":
                if let session = model.selectedSession { model.reviews.toggle(session) }
            case "snap":
                snap(to: dir.appendingPathComponent("\(rest).png"))
            case "scroll":
                await scroll(steps: Int(rest) ?? 50)
            case "top":
                await scroll(steps: 0)
            case "size":
                if words.count == 3, let w = Double(words[1]), let h = Double(words[2]), let window = mainWindow {
                    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: w, height: h)), display: true)
                }
            case "pr":
                if words.count == 3, let n = Int(words[2]), let id = model.selectedSessionID {
                    model.reviews.setSource(id, .pullRequest(repo: words[1], number: n))
                }
            case "folder":
                if let id = model.selectedSessionID { model.reviews.setSource(id, .folder(rest)) }
            case "base":
                if let id = model.selectedSessionID { model.reviews.setBase(id, rest.isEmpty ? nil : rest) }
            case "window":
                guard mainWindow == nil else { break }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: ContentView().environment(model))
                w.orderFront(nil)
                window = w
                model.start()
                try? await Task.sleep(for: .seconds(2))
            case "wait":
                try? await Task.sleep(for: .seconds(Double(rest) ?? 1))
            default:
                // The review's own commands (ReviewPanel, ReviewDiffView): filter, layers, overview, jump, expand,
                // key <j k n p v c ? ⌥↓ ⌥↑ esc>, range, say, suggest, queue.
                NotificationCenter.default.post(name: .simulDevCommand, object: String(line))
                try? await Task.sleep(for: .milliseconds(300))
                log("posted: \(line)")
            }
        }
        log("done")
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }.max { $0.frame.width < $1.frame.width } ?? window
    }

    private static func snap(to url: URL) {
        guard let view = mainWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return log("snap: no window")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("snap: \(url.lastPathComponent)")
    }

    /// The tallest scroll view in the window that isn't a terminal: the review's file list.
    private static func scroll(steps: Int) async {
        guard let root = mainWindow?.contentView else { return log("scroll: no window") }
        var views: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { views.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let scroll = views.max(by: { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }) else {
            return log("scroll: no scroll view")
        }
        guard steps != 0 else {
            scroll.contentView.scroll(to: .zero)
            return scroll.reflectScrolledClipView(scroll.contentView)
        }
        var times: [Double] = []
        for _ in 0..<abs(steps) {
            let start = CACurrentMediaTime()
            var origin = scroll.contentView.bounds.origin
            origin.y = max(0, min(origin.y + (steps > 0 ? 80 : -80),
                                  max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            times.append((CACurrentMediaTime() - start) * 1000)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let sorted = times.sorted()
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let screen = root.window?.screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))" } ?? "?"
        log(String(format: "scroll %d steps: median %.1f ms, p90 %.1f ms, max %.1f ms, over 16ms: %d (%@%@)",
                   steps, p(0.5), p(0.9), sorted.last ?? 0, times.filter { $0 > 16 }.count,
                   screen, NSApp.isActive ? ", active" : ""))
        log("  slow steps: " + times.indices.filter { times[$0] > 16 }.map { String(format: "%d (%.0f)", $0, times[$0]) }.joined(separator: ", "))
    }

    private static func log(_ message: String) {
        let url = Paths.applicationSupport.appendingPathComponent("devlog")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((message + "\n").utf8))
            try? handle.close()
        }
    }
}

extension Notification.Name {
    /// A DevHooks command for the views (only posted with SIMUL_DEV_HOOKS=1).
    static let simulDevCommand = Notification.Name("sh.simul.devCommand")
}
