import AppKit
import SwiftUI

enum Tab: String, CaseIterable {
    case library = "Library", running = "Running", logs = "Logs"
    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .running: return "cpu"
        case .logs: return "text.alignleft"
        }
    }
}

@MainActor
final class Nav: ObservableObject {
    @Published var tab: Tab = .library
    @Published var logPath: String?
}

func bytes(_ b: Int64) -> String { b < 1_000_000_000 ? "\(b / 1_000_000) MB" : formatGB(Double(b) / 1e9) }

// MARK: Shell

struct MainPane: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var manager: ManagerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button { nav.tab = tab } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                            if tab == .running && !manager.servers.isEmpty {
                                Text("\(manager.servers.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.green.opacity(0.25)))
                                    .foregroundStyle(Theme.green)
                            }
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(nav.tab == tab ? Color.white.opacity(0.10) : .clear))
                        .overlay(Capsule().strokeBorder(nav.tab == tab ? Theme.violet.opacity(0.5) : .clear))
                        .foregroundStyle(nav.tab == tab ? .white : Theme.dim)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Chip(text: "Ollama port \(Ollama.port)", color: Ollama.port == Ollama.defaultPort ? Theme.dim : Theme.amber)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)

            switch nav.tab {
            case .library: LibraryView()
            case .running: RunningView()
            case .logs: LogsView()
            }
        }
        .onAppear { manager.start() }
        .onChange(of: nav.tab) { manager.fast = $0 != .library }
    }
}

// MARK: Running

struct RunningView: View {
    @EnvironmentObject var manager: ManagerModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let e = manager.error {
                    Banner(text: e, color: Theme.red, icon: "exclamationmark.triangle.fill") { manager.error = nil }
                }
                if let n = manager.notice {
                    Banner(text: n, color: Theme.green, icon: "checkmark.seal.fill") { manager.notice = nil }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Running agents").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Chip(text: "\(manager.servers.count) server\(manager.servers.count == 1 ? "" : "s")", color: Theme.cyan)
                    Chip(text: "\(manager.loadedCount) model\(manager.loadedCount == 1 ? "" : "s") loaded", color: Theme.magenta)
                    Chip(text: "\(bytes(manager.memoryInUse)) in use", color: Theme.violet)
                    Button { Task { await manager.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(GhostButton()).help("Refresh now")
                }
                Text("Every local model server on this Mac, the models each one has in memory and the runner process serving them.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)

                if !manager.scanned {
                    HStack { ProgressView().controlSize(.small); Text("Scanning…").foregroundStyle(Theme.dim) }.padding(30)
                } else if manager.servers.isEmpty {
                    Card(padding: 28) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "moon.zzz").font(.system(size: 26)).foregroundStyle(Theme.violet)
                            Text("No local model servers are running").font(.system(size: 15, weight: .semibold))
                            Text("Looked for Ollama, llama.cpp, LM Studio, MLX, vLLM, KoboldCpp, LocalAI and Jev.")
                                .font(.system(size: 12)).foregroundStyle(Theme.dim)
                            if Ollama.appURL != nil {
                                Button("Start Ollama") { manager.run("start-ollama", success: "Ollama started.") { try await Ollama.launch() } }
                                    .buttonStyle(PrimaryButton(compact: true))
                            }
                        }
                    }
                }
                ForEach(manager.servers) { ServerCard(server: $0) }

                Text("Runner ports are chosen by Ollama for each loaded model and change when it reloads; the server port is the one apps and the site connect to.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
            .padding(24)
        }
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(minWidth: 62, alignment: .trailing)
    }
}

struct ServerCard: View {
    @EnvironmentObject var manager: ManagerModel
    @EnvironmentObject var nav: Nav
    let server: Server
    @State private var portSheet = false
    @State private var confirmStop = false

    var body: some View {
        let s = server
        let busy = manager.busy.contains { $0.hasSuffix("-\(s.pid)") }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.violet.opacity(0.5), Theme.cyan.opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: s.engine == .ollama ? "brain.head.profile" : "server.rack").font(.system(size: 18))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.green).frame(width: 7, height: 7).shadow(color: Theme.green, radius: 4)
                        Text(s.engine.rawValue).font(.system(size: 15, weight: .semibold))
                        if let v = s.version { Text("v\(v)").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                        if s.isMain { Chip(text: "Used by Infinite Agent", color: Theme.magenta) }
                        if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    }
                    Text("\(s.management.label) · up \(s.proc.elapsed)")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Stat(label: "Port", value: s.ports.map(String.init).joined(separator: ", "))
                Stat(label: "PID", value: "\(s.pid)")
                Stat(label: "CPU", value: String(format: "%.0f%%", s.proc.cpu + s.runnerCPU))
                Stat(label: "Memory", value: bytes(s.proc.rssBytes + s.runnerRSS))
            }

            HStack(spacing: 8) {
                if s.engine == .ollama {
                    Button { portSheet = true } label: { Label("Change port", systemImage: "number") }
                        .buttonStyle(GhostButton())
                }
                Button { manager.restart(s) } label: { Label("Restart", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(GhostButton(tint: Theme.cyan))
                    .disabled(!s.canRestart || busy)
                    .help(s.canRestart ? "Restart this server" : "Started by hand: restart it where you launched it")
                Button { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(GhostButton(tint: Theme.red)).disabled(busy)
                Button {
                    nav.logPath = LogSource.available(servers: [s]).first { $0.name != "Agent Manager activity" }?.path
                    nav.tab = .logs
                } label: { Label("Logs", systemImage: "text.alignleft") }
                    .buttonStyle(GhostButton())
                Spacer()
                if s.engine == .ollama {
                    let idle = s.installed.filter { n in !s.loaded.contains { $0.id == n } && !n.contains("embed") }
                    Menu {
                        ForEach(idle, id: \.self) { name in
                            Button(name) { manager.load(name, on: s) }
                        }
                    } label: { Label("Load model", systemImage: "plus.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(idle.isEmpty)
                } else if let port = s.apiPort {
                    Text(verbatim: "http://127.0.0.1:\(port)/v1").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                        .textSelection(.enabled)
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            if s.engine == .ollama {
                if s.loaded.isEmpty {
                    Text("No models in memory. Ollama loads a model on its first request and unloads it after it has been idle (5 min by default).")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                ForEach(s.loaded) { LoadedRow(model: $0, server: s) }
                ForEach(s.orphanRunners, id: \.pid) { r in
                    Text("Runner pid \(r.pid) on port \(r.port.map(String.init) ?? "?") · \(bytes(r.rssBytes)) · not matched to a model")
                        .font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
            } else {
                Text(s.apiModels.isEmpty ? "No model list at /v1/models." : "Models: " + s.apiModels.joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                Text(s.proc.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim.opacity(0.7))
                    .lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(s.isMain ? Theme.violet.opacity(0.45) : Theme.stroke))
        .sheet(isPresented: $portSheet) { PortSheet(server: s) }
        .confirmationDialog(String("Stop \(s.engine.rawValue) on port \(s.apiPort ?? 0)?"), isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { manager.stopServer(s) }
        } message: {
            Text(s.isMain ? "The Infinite Agent can't use local models until it's started again." : "Apps using this server will lose their connection.")
        }
    }
}

struct LoadedRow: View {
    @EnvironmentObject var manager: ManagerModel
    let model: LoadedModel
    let server: Server

    var expiry: String {
        guard let d = model.info.expires else { return "" }
        let left = d.timeIntervalSinceNow
        if left > 86_400 * 365 { return "Always loaded" }
        if left <= 0 { return "Unloading" }
        return left < 3600 ? "Unloads in \(Int(left / 60) + 1) min" : String(format: "Unloads in %.1f h", left / 3600)
    }

    var body: some View {
        let m = model.info
        let gpu = m.gpuShare
        let busy = manager.busy.contains("model-\(server.pid)-\(model.id)")
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(m.name).font(.system(size: 13, weight: .semibold))
                    Chip(text: gpu >= 0.99 ? "100% GPU" : gpu <= 0.01 ? "CPU only" : "\(Int(gpu * 100))% GPU / \(100 - Int(gpu * 100))% CPU",
                         color: gpu >= 0.99 ? Theme.green : gpu <= 0.01 ? Theme.amber : Theme.cyan)
                    if let c = m.context_length { Chip(text: "\(c / 1024)k ctx") }
                    Chip(text: expiry, color: Theme.dim)
                }
                Text(runnerText).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Stat(label: "Size", value: bytes(m.size))
            if let r = model.runner {
                Stat(label: "CPU", value: String(format: "%.0f%%", r.cpu))
            }
            if busy { ProgressView().controlSize(.small) }
            Button("Reload") { manager.reload(model, on: server) }.buttonStyle(GhostButton(tint: Theme.cyan)).disabled(busy)
            Button("Unload") { manager.unload(model, on: server) }.buttonStyle(GhostButton(tint: Theme.red)).disabled(busy)
            Menu {
                ForEach([("5 minutes", "5m"), ("30 minutes", "30m"), ("2 hours", "2h"), ("Always", "-1")], id: \.1) { label, v in
                    Button(label) { manager.load(m.name, on: server, keepAlive: v, context: m.context_length) }
                }
            } label: { Image(systemName: "timer") }
                .menuStyle(.borderlessButton).fixedSize().help("Keep loaded for…")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    var runnerText: String {
        guard let r = model.runner else { return "runner process not found" }
        return "runner pid \(r.pid) · port \(r.port.map(String.init) ?? "?") · \(bytes(r.rssBytes)) resident"
    }
}

struct PortSheet: View {
    @EnvironmentObject var manager: ManagerModel
    @Environment(\.dismiss) private var dismiss
    let server: Server
    @State private var text = ""

    var port: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    var valid: Bool { port.map { (1024...65535).contains($0) && !server.ports.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Ollama's port").font(.system(size: 17, weight: .bold))
            Text("Currently \(server.ports.map(String.init).joined(separator: ", ")) · \(server.management.label)")
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            TextField("Port, e.g. 11435", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).frame(width: 200)
            Text("Sets OLLAMA_HOST=127.0.0.1:\(port.map(String.init) ?? "…") for this Mac (kept after you log out) and restarts Ollama. Every Ollama server started afterwards uses it.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            if server.isMain {
                Text("The site connects to localhost:11434 by default. After a change, enter http://localhost:\(port.map(String.init) ?? "PORT") as the Ollama address in the Infinite Agent's AI settings.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !server.ports.contains(Ollama.defaultPort) {
                    Button("Reset to \(String(Ollama.defaultPort))") {
                        manager.changePort(server, to: Ollama.defaultPort); dismiss()
                    }.buttonStyle(GhostButton())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
                Button("Change and restart") {
                    if let port { manager.changePort(server, to: port) }
                    dismiss()
                }
                .buttonStyle(PrimaryButton(compact: true)).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bgTop)
        .preferredColorScheme(.dark)
    }
}

// MARK: Logs

struct LogsView: View {
    @EnvironmentObject var manager: ManagerModel
    @EnvironmentObject var nav: Nav
    @State private var sources: [LogSource] = []
    @State private var lines: [String] = []
    @State private var filter = ""
    @State private var problemsOnly = false
    @State private var follow = true
    @State private var hideRequests = true

    var selected: LogSource? { sources.first { $0.path == nav.logPath } ?? sources.first }

    var shown: [(Int, String)] {
        Array(lines.enumerated()).filter { _, l in
            (!problemsOnly || level(l) != nil) && !(hideRequests && routineRequest(l))
                && (filter.isEmpty || l.localizedCaseInsensitiveContains(filter))
        }
    }

    /// `[GIN] 2026/10/30 - 13:49:01 | 200 | 45µs | 127.0.0.1 | GET "/api/version"` with a 2xx/3xx status.
    func routineRequest(_ l: String) -> Bool {
        guard l.hasPrefix("[GIN]") else { return false }
        let fields = l.split(separator: "|")
        guard fields.count > 1, let code = Int(fields[1].trimmingCharacters(in: .whitespaces)) else { return false }
        return code < 400
    }

    func level(_ l: String) -> Color? {
        let u = l.uppercased()
        if u.contains("LEVEL=ERROR") || u.contains(" ERROR") || u.contains("PANIC") || u.contains("FATAL") { return Theme.red }
        if u.contains("LEVEL=WARN") || u.contains(" WARN") { return Theme.amber }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Log", selection: Binding(get: { selected?.path ?? "" }, set: { nav.logPath = $0 })) {
                    ForEach(sources) { Text($0.name).tag($0.path) }
                }
                .labelsHidden().frame(width: 230)
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shown.map(\.1).joined(separator: "\n"), forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }.buttonStyle(GhostButton()).help("Copy shown lines")
                Button { if let p = selected?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
                    label: { Image(systemName: "folder") }.buttonStyle(GhostButton()).help("Show in Finder")
                Button { if let p = selected?.path { shell("/usr/bin/open", ["-a", "Console", p]) } }
                    label: { Label("Console", systemImage: "terminal") }.buttonStyle(GhostButton()).fixedSize().help("Open in Console")
            }
            HStack(spacing: 14) {
                Text(selected?.path ?? "No logs found yet.")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Toggle("Problems only", isOn: $problemsOnly).toggleStyle(.checkbox).fixedSize()
                Toggle("Hide HTTP requests", isOn: $hideRequests).toggleStyle(.checkbox).fixedSize()
                    .help("Hides routine 2xx/3xx request lines; failed requests stay visible")
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).fixedSize()
            }
            .font(.system(size: 12))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown, id: \.0) { i, l in
                            Text(l.isEmpty ? " " : l)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(level(l) ?? .white.opacity(0.82))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(i)
                        }
                        Color.clear.frame(height: 1).id(-1)
                    }
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                .onChange(of: lines.count) { _ in if follow { proxy.scrollTo(-1, anchor: .bottom) } }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        .task(id: nav.logPath) {
            while !Task.isCancelled {
                let servers = manager.servers
                let found = await Task.detached { LogSource.available(servers: servers) }.value
                sources = found
                if let src = sources.first(where: { $0.path == nav.logPath }) ?? sources.first {
                    let tail = await Task.detached { src.tail() }.value
                    if tail != lines { lines = tail }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
