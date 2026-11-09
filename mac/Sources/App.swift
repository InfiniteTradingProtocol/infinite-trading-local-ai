import AppKit
import SwiftUI

struct AgentManagerApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var manager = ManagerModel()
    @StateObject private var nav = Nav()
    @StateObject private var updates = UpdateModel()

    var body: some Scene {
        Window("Infinite Agent Manager", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(manager)
                .environmentObject(nav)
                .environmentObject(updates)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updates.check(userInitiated: true) } }
                Button("What's New…") { nav.showChangelog = true }
                Toggle("Install Updates Automatically", isOn: $updates.autoInstall)
            }
            CommandMenu("View") {
                ForEach(Array(Tab.allCases.enumerated()), id: \.offset) { i, tab in
                    Button(tab.rawValue) { nav.tab = tab }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
            CommandMenu("Connection") {
                Button("Open Infinite Agent") { app.openAgent() }.keyboardShortcut("o")
                Button("Check Again") { Task { await app.refresh(); await manager.refresh() } }.keyboardShortcut("r")
                Divider()
                Button("Stop Allowing Infinite Trading") { Task { await app.disconnectSite() } }
                    .disabled(!app.siteAllowed)
            }
        }
    }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[i + 1]))
        } else {
            AgentManagerApp.main()
        }
    }

    /// Renders the window offscreen to a PNG (for docs and design review).
    static func snapshot(to url: URL, args: [String] = CommandLine.arguments) {
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = AppModel()
            let manager = ManagerModel()
            let nav = Nav()
            if let t = args.firstIndex(of: "--tab"), t + 1 < args.count, let tab = Tab(rawValue: args[t + 1].capitalized) {
                nav.tab = tab
            }
            await model.refresh()
            if ProcessInfo.processInfo.environment["ILA_DEMO"] == "1" { manager.loadDemo() } else { await manager.refresh() }
            let size = NSSize(width: Double(ProcessInfo.processInfo.environment["ILA_WIDTH"] ?? "") ?? 1120, height: Double(ProcessInfo.processInfo.environment["ILA_HEIGHT"] ?? "") ?? 760)
            let host = NSHostingView(rootView: RootView().environmentObject(model).environmentObject(manager).environmentObject(nav).environmentObject(UpdateModel()).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            exit(0)
        }
        nsApp.run()
    }
}
