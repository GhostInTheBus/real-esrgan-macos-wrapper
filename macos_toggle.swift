import Cocoa
import Foundation

final class ToggleController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let projectRoot = "/Users/Joe/real-esrgan-web-app"
    private var window: NSWindow!
    private var toggle: NSSwitch!
    private var status: NSTextField!
    private var serverProcess: Process?
    private var openedBrowser = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))

        let title = NSTextField(labelWithString: "Real-ESRGAN Upscaler")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 24, y: 102, width: 312, height: 26)
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Image and video upscaling")
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: 78, width: 250, height: 20)
        content.addSubview(subtitle)

        toggle = NSSwitch(frame: NSRect(x: 275, y: 76, width: 60, height: 24))
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        toggle.controlSize = .regular
        content.addSubview(toggle)

        status = NSTextField(labelWithString: "Checking status…")
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 24, y: 32, width: 312, height: 20)
        content.addSubview(status)

        window = NSWindow(contentRect: content.bounds,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Real-ESRGAN"
        window.contentView = content
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        updateStatus()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        if sender.state == .on {
            startServer()
        } else {
            stopServer()
        }
    }

    private func startServer() {
        if serverRunning() { return }
        status.stringValue = "Starting…"
        openedBrowser = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["\(projectRoot)/run_native.sh"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "STREAMLIT_BROWSER_GATHER_USAGE_STATS": "false"]
        let logURL = URL(fileURLWithPath: "\(projectRoot)/output/native.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardOutput = try? FileHandle(forWritingTo: logURL)
        process.standardError = process.standardOutput
        do {
            try process.run()
            serverProcess = process
        } catch {
            status.stringValue = "Could not start — see native.log"
            toggle.state = .off
        }
    }

    private func stopServer() {
        status.stringValue = "Stopping…"
        _ = shell("/usr/sbin/lsof -tiTCP:8501 -sTCP:LISTEN").split(separator: "\n").map {
            _ = shell("/bin/kill \(String($0))")
        }
        serverProcess = nil
    }

    private func updateStatus() {
        let running = serverRunning()
        if toggle.state != (running ? .on : .off) { toggle.state = running ? .on : .off }
        if running {
            status.stringValue = "ON — running at 127.0.0.1:8501"
            if !openedBrowser {
                openedBrowser = true
                NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8501")!)
            }
        } else if status.stringValue == "ON — running at 127.0.0.1:8501" || status.stringValue == "Stopping…" {
            status.stringValue = "OFF"
        } else if status.stringValue == "Checking status…" {
            status.stringValue = "OFF"
        }
    }

    private func serverRunning() -> Bool {
        let result = shell("/usr/bin/curl -fsS --max-time 1 http://127.0.0.1:8501/")
        return !result.isEmpty
    }

    @discardableResult
    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if serverRunning() { stopServer() }
        NSApp.terminate(nil)
        return true
    }
}

let app = NSApplication.shared
let controller = ToggleController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
