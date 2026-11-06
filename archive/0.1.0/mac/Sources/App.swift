import AppKit
import SwiftUI

struct LocalAIApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Infinite Local AI", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Connection") {
                Button("Open Infinite Agent") { app.openAgent() }.keyboardShortcut("o")
                Button("Check Again") { Task { await app.refresh() } }.keyboardShortcut("r")
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
            LocalAIApp.main()
        }
    }

    /// Renders the window offscreen to a PNG (for docs and design review).
    static func snapshot(to url: URL) {
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let model = AppModel()
            await model.refresh()
            let size = NSSize(width: 1120, height: 760)
            let host = NSHostingView(rootView: RootView().environmentObject(model).frame(width: size.width, height: size.height))
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
