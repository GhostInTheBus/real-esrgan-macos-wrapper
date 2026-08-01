import Cocoa
import SwiftUI
import Combine
import UserNotifications
import ServiceManagement

class AppState: ObservableObject {
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var statusText = "Checking status..."
    @Published var launchAtLogin = false
}

struct PopoverView: View {
    @ObservedObject var state: AppState
    let toggleAction: (Bool) -> Void
    let launchAtLoginAction: (Bool) -> Void
    let openBrowserAction: () -> Void
    let viewLogsAction: () -> Void
    let quitAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Real-ESRGAN")
                        .font(.headline)
                    Text("Upscaler")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Server Status")
                        .font(.body)
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundColor(state.isRunning ? .green : (state.isStarting ? .orange : .secondary))
                }
                Spacer()
                if state.isStarting {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                Toggle("", isOn: Binding(
                    get: { self.state.isRunning || self.state.isStarting },
                    set: { newValue in self.toggleAction(newValue) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
            }
            
            Divider()
            
            if #available(macOS 13.0, *) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { self.state.launchAtLogin },
                    set: { newValue in self.launchAtLoginAction(newValue) }
                ))
                .toggleStyle(CheckboxToggleStyle())
                .font(.subheadline)
                
                Divider()
            }

            VStack(spacing: 8) {
                Button(action: openBrowserAction) {
                    HStack {
                        Image(systemName: "safari")
                        Text("Open in Browser")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(state.isRunning ? .primary : .secondary)
                .disabled(!state.isRunning)

                Button(action: viewLogsAction) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("View Logs")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: quitAction) {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 250)
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let projectRoot = "/Users/Joe/real-esrgan-web-app"
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    
    private var serverProcess: Process?
    private var updateTimer: Timer?
    
    private let appState = AppState()
    private var wasRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Real-ESRGAN")
            if button.image == nil { button.title = "✨" }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        if #available(macOS 13.0, *) {
            appState.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        let view = PopoverView(
            state: appState,
            toggleAction: { [weak self] isOn in
                if isOn { self?.startServer() }
                else { self?.stopServer() }
            },
            launchAtLoginAction: { [weak self] isOn in
                self?.toggleLaunchAtLogin(isOn)
            },
            openBrowserAction: { [weak self] in self?.openBrowser() },
            viewLogsAction: { [weak self] in self?.viewLogs() },
            quitAction: { [weak self] in self?.quitApp() }
        )
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 250, height: 260)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)

        updateStatus()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }
    
    private func toggleLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                appState.launchAtLogin = enable
            } catch {
                print("Failed to toggle launch at login: \(error)")
                // Revert state on failure
                appState.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    private func showPopover(sender: AnyObject?) {
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover(sender: AnyObject?) {
        popover.performClose(sender)
    }

    private func startServer() {
        if serverRunning() { return }
        appState.isStarting = true
        appState.statusText = "Starting..."
        updateIcon()
        
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
            appState.isStarting = false
            appState.statusText = "Failed to start"
        }
    }

    private func stopServer() {
        appState.isStarting = false
        serverProcess?.terminate()
        serverProcess = nil
        _ = shell("/usr/sbin/lsof -tiTCP:8501 -sTCP:LISTEN").split(separator: "\n").map {
            _ = shell("/bin/kill \(String($0))")
        }
        serverProcess = nil
        appState.isRunning = false
        appState.statusText = "OFF"
        updateIcon()
    }

    private func openBrowser() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:8501")!)
        closePopover(sender: nil)
    }

    private func viewLogs() {
        let logURL = URL(fileURLWithPath: "\(projectRoot)/output/native.log")
        NSWorkspace.shared.open(logURL)
        closePopover(sender: nil)
    }

    private func quitApp() {
        if serverRunning() {
            stopServer()
        }
        NSApp.terminate(nil)
    }

    private func updateStatus() {
        let running = serverRunning()
        
        DispatchQueue.main.async {
            self.appState.isRunning = running
            
            if running {
                self.appState.isStarting = false
                self.appState.statusText = "ON (Port 8501)"
            } else if self.appState.isStarting && (self.serverProcess?.isRunning ?? false) {
                self.appState.statusText = "Starting..."
            } else {
                self.appState.isStarting = false
                self.appState.statusText = "OFF"
            }
            
            self.updateIcon()
            
            if running && !self.wasRunning {
                self.sendNotification(title: "Upscaler Ready", body: "Real-ESRGAN server is now running.")
            }
            self.wasRunning = running
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    // Delegate method to show notifications even when app is active (in foreground)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    private func updateIcon() {
        if let button = statusItem.button {
            if appState.isRunning {
                button.image = NSImage(systemSymbolName: "wand.and.stars.inverse", accessibilityDescription: "Running")
                if button.image == nil { button.title = "🌟" }
            } else {
                button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Ready")
                if button.image == nil { button.title = "✨" }
            }
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
}

let app = NSApplication.shared
let controller = MenuBarController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
