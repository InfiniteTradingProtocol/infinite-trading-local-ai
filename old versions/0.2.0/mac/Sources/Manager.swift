import AppKit
import Foundation

// Agent manager: finds every local model server (any engine), the models each
// one has loaded and their runner processes, and restarts, stops, re-ports
// and tails the logs of them. Process facts come from ps, lsof and
// `launchctl list`; Ollama details from its HTTP API.

enum Engine: String {
    case ollama = "Ollama", llamaCpp = "llama.cpp", lmStudio = "LM Studio", mlx = "MLX LM",
         vllm = "vLLM", kobold = "KoboldCpp", localAI = "LocalAI", jev = "Jev"

    static func detect(_ command: String) -> Engine? {
        let c = command.lowercased()
        let exe = URL(fileURLWithPath: String(command.split(separator: " ").first ?? "")).lastPathComponent.lowercased()
        if exe == "ollama" && c.contains(" serve") { return .ollama }
        if c.contains("ollama runner") { return nil } // a runner, grouped under its server
        if exe == "llama-server" { return .llamaCpp }
        if c.contains("lm studio") || exe == "lms" { return .lmStudio }
        if c.contains("mlx_lm.server") || c.contains("mlx_lm server") { return .mlx }
        if c.contains("vllm") { return .vllm }
        if c.contains("koboldcpp") { return .kobold }
        if exe == "local-ai" { return .localAI }
        if exe == "jev" || c.contains("/jev ") || c.contains("jev serve") { return .jev }
        return nil
    }
}

struct Proc {
    let pid: Int32
    let ppid: Int32
    let rssBytes: Int64
    let cpu: Double
    let elapsed: String
    let command: String
}

enum Management: Equatable {
    case ollamaApp, launchd(String), manual

    var label: String {
        switch self {
        case .ollamaApp: return "Ollama app"
        case .launchd(let l): return "launchd · \(l)"
        case .manual: return "Started manually"
        }
    }
}

struct Runner: Hashable {
    let pid: Int32
    let port: Int?
    let blob: String
    let rssBytes: Int64
    let cpu: Double
    let context: Int?
}

struct LoadedModel: Identifiable {
    var id: String { info.name }
    let info: Ollama.Loaded
    let runner: Runner?
}

struct Server: Identifiable {
    var id: Int32 { pid }
    let engine: Engine
    let pid: Int32
    let ports: [Int]
    let proc: Proc
    let management: Management
    var version: String?
    var loaded: [LoadedModel] = []
    var installed: [String] = []
    var orphanRunners: [Runner] = []
    var apiModels: [String] = []
    var runnerCPU: Double = 0
    var runnerRSS: Int64 = 0

    var apiPort: Int? { ports.sorted().first }
    var base: URL? { apiPort.map(Ollama.url(port:)) }
    var isMain: Bool { engine == .ollama && ports.contains(Ollama.port) }
    var canRestart: Bool { management != .manual || engine == .ollama }
}

enum Discovery {
    static func processes() -> [Int32: Proc] {
        var table: [Int32: Proc] = [:]
        for line in shell("/bin/ps", ["-axww", "-o", "pid=,ppid=,rss=,%cpu=,etime=,command="]).out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            table[pid] = Proc(pid: pid, ppid: ppid, rssBytes: (Int64(f[2]) ?? 0) * 1024,
                              cpu: Double(f[3]) ?? 0, elapsed: String(f[4]), command: String(f[5]))
        }
        return table
    }

    /// TCP listening ports per pid (current user's processes).
    static func listening() -> [Int32: [Int]] {
        var out: [Int32: [Int]] = [:]
        var pid: Int32?
        for line in shell("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]).out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid, let port = Int(line.split(separator: ":").last ?? ""),
                    !(out[pid]?.contains(port) ?? false) {
                out[pid, default: []].append(port)
            }
        }
        return out
    }

    /// pid → launchd label for the user's running services.
    static func launchdLabels() -> [Int32: String] {
        var out: [Int32: String] = [:]
        for line in shell("/bin/launchctl", ["list"]).out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t")
            if f.count == 3, let pid = Int32(f[0]) { out[pid] = String(f[2]) }
        }
        return out
    }

    static func runner(_ p: Proc) -> Runner? {
        let c = p.command
        guard c.contains("--port"), c.contains("--model"),
              c.contains("ollama runner") || c.contains("llama-server") else { return nil }
        func arg(_ names: [String]) -> String? {
            let parts = c.split(separator: " ").map(String.init)
            for (i, part) in parts.enumerated() where names.contains(part) && i + 1 < parts.count { return parts[i + 1] }
            return nil
        }
        return Runner(pid: p.pid, port: arg(["--port"]).flatMap(Int.init),
                      blob: arg(["--model"]).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                      rssBytes: p.rssBytes, cpu: p.cpu, context: arg(["-c", "--ctx-size"]).flatMap(Int.init))
    }

    /// Process-level view of every model server. No HTTP; see `ManagerModel.refresh`.
    static func scan() -> [Server] {
        let procs = processes()
        let ports = listening()
        let labels = launchdLabels()
        var servers: [Server] = []
        for (pid, p) in procs {
            guard let engine = Engine.detect(p.command) else { continue }
            // A llama-server spawned by Ollama is a runner, not a server.
            if engine == .llamaCpp, let parent = procs[p.ppid], Engine.detect(parent.command) == .ollama { continue }
            // Helper processes (LM Studio has several) only count if they listen.
            guard let listen = ports[pid], !listen.isEmpty else { continue }
            let management: Management =
                p.command.contains("/Ollama.app/") || (procs[p.ppid]?.command.contains("/Ollama.app/") ?? false) ? .ollamaApp
                : labels[pid].map(Management.launchd) ?? .manual
            var s = Server(engine: engine, pid: pid, ports: listen.sorted(), proc: p, management: management)
            let runners = procs.values.filter { $0.ppid == pid }.compactMap(runner)
            s.orphanRunners = runners
            s.runnerCPU = runners.reduce(0) { $0 + $1.cpu }
            s.runnerRSS = runners.reduce(0) { $0 + $1.rssBytes }
            servers.append(s)
        }
        return servers.sorted { ($0.isMain ? 0 : 1, $0.apiPort ?? 0) < ($1.isMain ? 0 : 1, $1.apiPort ?? 0) }
    }

    static func portOwner(_ port: Int) -> Int32? {
        listening().first { $0.value.contains(port) }?.key
    }
}

// MARK: Control

enum Control {
    static var uid: String { String(getuid()) }

    static func restart(_ s: Server, newPort: Int? = nil) async throws {
        let port = s.apiPort ?? Ollama.port
        let target = newPort ?? port
        Activity.log("Restarting \(s.engine.rawValue) pid \(s.pid) (\(s.management.label)) on port \(port)" +
                     (newPort.map { " → \($0)" } ?? ""))
        switch s.management {
        case .ollamaApp:
            try await Ollama.restartApp(port: port, newPort: target)
            return
        case .launchd(let label):
            let r = shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])
            guard r.status == 0 else { throw Ollama.Failure("launchctl kickstart \(label) failed: \(r.err.prefix(200))") }
        case .manual:
            guard s.engine == .ollama else {
                throw Ollama.Failure("\(s.engine.rawValue) was started by hand; restart it where you launched it.")
            }
            try await terminate(s.pid, port: port)
            try spawnOllama(binary: String(s.proc.command.split(separator: " ").first ?? ""), port: target)
        }
        if s.engine == .ollama, !(await Ollama.waitForServer(at: Ollama.url(port: target), up: true, seconds: 30)) {
            throw Ollama.Failure("\(s.engine.rawValue) didn't come back on port \(target).")
        }
    }

    static func stop(_ s: Server) async throws {
        Activity.log("Stopping \(s.engine.rawValue) pid \(s.pid) (\(s.management.label))")
        switch s.management {
        case .ollamaApp:
            Ollama.quitApp()
        case .launchd(let label):
            // bootout unloads it until next login; kill alone would let KeepAlive respawn it.
            let r = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            guard r.status == 0 else { throw Ollama.Failure("launchctl bootout \(label) failed: \(r.err.prefix(200))") }
        case .manual:
            try await terminate(s.pid, port: s.apiPort)
        }
    }

    /// Moves an Ollama server to another port via OLLAMA_HOST, then restarts it.
    static func changePort(_ s: Server, to port: Int) async throws {
        guard s.engine == .ollama else { throw Ollama.Failure("Only Ollama's port can be changed from here.") }
        guard (1024...65535).contains(port) else { throw Ollama.Failure("Pick a port between 1024 and 65535.") }
        if let owner = Discovery.portOwner(port), owner != s.pid {
            throw Ollama.Failure("Port \(port) is already used by pid \(owner).")
        }
        let previous = OllamaEnv.get("OLLAMA_HOST")
        try OllamaEnv.set("OLLAMA_HOST", port == Ollama.defaultPort ? nil : "127.0.0.1:\(port)")
        do {
            try await restart(s, newPort: port)
        } catch {
            try? OllamaEnv.set("OLLAMA_HOST", previous.isEmpty ? nil : previous)
            throw Ollama.Failure("\(error.localizedDescription) Port setting reverted.")
        }
        if s.isMain || s.ports.contains(Ollama.port) { Ollama.port = port }
        Activity.log("Ollama now listens on port \(port)")
    }

    private static func terminate(_ pid: Int32, port: Int?) async throws {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 500_000_000)
        if kill(pid, 0) == 0 { throw Ollama.Failure("Process \(pid) didn't stop.") }
    }

    private static func spawnOllama(binary: String, port: Int) throws {
        let log = URL(fileURLWithPath: NSHomeDirectory() + "/.ollama/logs/server.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary.isEmpty ? (Ollama.cliPath ?? "ollama") : binary)
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        let origins = OllamaEnv.get("OLLAMA_ORIGINS")
        if !origins.isEmpty { env["OLLAMA_ORIGINS"] = origins }
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
    }
}

// MARK: Logs

struct LogSource: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String

    static func available(servers: [Server]) -> [LogSource] {
        let home = NSHomeDirectory()
        var list: [LogSource] = []
        for s in servers {
            if case .launchd(let label) = s.management, let path = launchdLog(label) {
                list.append(LogSource(name: "\(s.engine.rawValue) · \(label)", path: path))
            }
        }
        let known: [(String, String)] = [
            ("Ollama server", "\(home)/.ollama/logs/server.log"),
            ("Ollama app", "\(home)/.ollama/logs/app.log"),
            ("Ollama (Homebrew)", "/opt/homebrew/var/log/ollama.log"),
            ("Ollama (Homebrew)", "/usr/local/var/log/ollama.log"),
        ]
        list += known.map(LogSource.init).filter { FileManager.default.fileExists(atPath: $0.path) }
        if let lms = newest(in: "\(home)/.lmstudio/server-logs") { list.append(LogSource(name: "LM Studio server", path: lms)) }
        list.append(LogSource(name: "Agent Manager activity", path: Activity.path.path))
        var seen = Set<String>()
        return list.filter { seen.insert($0.path).inserted }
    }

    static func launchdLog(_ label: String) -> String? {
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        for key in ["StandardErrorPath", "StandardOutPath"] {
            let r = shell("/usr/bin/plutil", ["-extract", key, "raw", plist])
            let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status == 0, !path.isEmpty { return path }
        }
        return nil
    }

    private static func newest(in dir: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        return files.map { "\(dir)/\($0)" }
            .max { ((try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast)
                 < ((try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast) }
    }

    /// Last `lines` lines from the final 512 KB of the file.
    func tail(_ lines: Int = 800) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return ["(Nothing logged here yet.)"] }
        guard let h = FileHandle(forReadingAtPath: path) else { return ["(Can't read \(path))"] }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 524_288 ? size - 524_288 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).map { String($0.prefix(600)) }
    }
}

/// What this app did, so restarts and port changes can be audited later.
enum Activity {
    static let path = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Infinite Agent Manager/activity.log")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path.path) { fm.createFile(atPath: path.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

// MARK: Manager state

@MainActor
final class ManagerModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var busy: Set<String> = []
    @Published var error: String?
    @Published var notice: String?
    @Published var scanned = false
    private var blobs: [String: String] = [:]
    private var poller: Task<Void, Never>?
    var demo = false
    /// Poll every 3 s while Running or Logs is open, every 15 s otherwise.
    var fast = false

    var loadedCount: Int { servers.reduce(0) { $0 + max($1.loaded.count, $1.apiModels.count) } }
    var memoryInUse: Int64 { servers.reduce(0) { $0 + $1.proc.rssBytes + $1.runnerRSS } }

    func start() {
        guard poller == nil, !demo else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let fast = self?.fast ?? false
                try? await Task.sleep(nanoseconds: fast ? 3_000_000_000 : 15_000_000_000)
            }
        }
    }

    func stop() { poller?.cancel(); poller = nil }

    func refresh() async {
        guard !demo else { return }
        var list = await Task.detached { Discovery.scan() }.value
        for i in list.indices {
            guard let base = list[i].base else { continue }
            if list[i].engine == .ollama {
                list[i].version = await Ollama.version(at: base)
                list[i].installed = await Ollama.tags(at: base).map(\.name)
                var runners = list[i].orphanRunners
                var models: [LoadedModel] = []
                let loaded = await Ollama.loaded(at: base)
                for m in loaded {
                    let key = "\(m.name)@\(m.digest ?? "")"
                    if blobs[key] == nil { blobs[key] = await Ollama.blob(of: m.name, at: base) ?? "" }
                    var match = runners.firstIndex { !(blobs[key] ?? "").isEmpty && $0.blob == blobs[key] }
                    if match == nil && loaded.count == 1 && runners.count == 1 { match = 0 }
                    let runner = match.map { runners.remove(at: $0) }
                    models.append(LoadedModel(info: m, runner: runner))
                }
                list[i].loaded = models
                list[i].orphanRunners = runners
            } else {
                list[i].apiModels = await openAIModels(at: base)
            }
        }
        servers = list
        scanned = true
    }

    /// OpenAI-compatible servers (llama.cpp, LM Studio, MLX, vLLM…) list models at /v1/models.
    private func openAIModels(at base: URL) async -> [String] {
        var r = URLRequest(url: base.appendingPathComponent("v1/models"))
        r.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }
    }

    func run(_ key: String, success: String? = nil, _ action: @escaping () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        error = nil
        Task {
            do {
                try await action()
                if let success { notice = success }
            } catch {
                self.error = error.localizedDescription
                Activity.log("Error: \(error.localizedDescription)")
            }
            busy.remove(key)
            await refresh()
        }
    }

    func restart(_ s: Server) {
        run("restart-\(s.pid)", success: "\(s.engine.rawValue) restarted.") { try await Control.restart(s) }
    }

    func stopServer(_ s: Server) {
        run("stop-\(s.pid)", success: "\(s.engine.rawValue) stopped.") { try await Control.stop(s) }
    }

    func changePort(_ s: Server, to port: Int) {
        let site = s.isMain && port != Ollama.defaultPort
        run("port-\(s.pid)", success: site
            ? "Ollama now uses port \(port). On the site, set the Ollama address to http://localhost:\(port)."
            : "Ollama now uses port \(port).") { try await Control.changePort(s, to: port) }
    }

    func unload(_ m: LoadedModel, on s: Server) {
        guard let base = s.base else { return }
        run("model-\(s.pid)-\(m.id)") {
            Activity.log("Unloading \(m.id) on port \(s.apiPort ?? 0)")
            try await Ollama.unload(m.id, at: base)
        }
    }

    func reload(_ m: LoadedModel, on s: Server) {
        guard let base = s.base else { return }
        run("model-\(s.pid)-\(m.id)", success: "\(m.id) reloaded.") {
            Activity.log("Reloading \(m.id) on port \(s.apiPort ?? 0)")
            try await Ollama.unload(m.id, at: base)
            try await Ollama.load(m.id, at: base, keepAlive: "30m", context: m.info.context_length)
        }
    }

    /// Sample data for `--snapshot` with ILA_DEMO=1 (design review on machines without servers).
    func loadDemo() {
        demo = true
        scanned = true
        let far = "2318-01-01T00:00:00Z"
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1260))
        func proc(_ pid: Int32, _ rss: Int64, _ cpu: Double, _ up: String, _ cmd: String) -> Proc {
            Proc(pid: pid, ppid: 1, rssBytes: rss, cpu: cpu, elapsed: up, command: cmd)
        }
        var app = Server(engine: .ollama, pid: 48211, ports: [Ollama.port],
                         proc: proc(48211, 180_000_000, 0.4, "2-03:11:42", "/Applications/Ollama.app/Contents/Resources/ollama serve"),
                         management: .ollamaApp)
        app.version = "0.40.13"
        app.installed = ["qwen3:14b", "gpt-oss:20b", "llama3.2:3b", "nomic-embed-text:latest"]
        app.loaded = [
            LoadedModel(info: .init(name: "qwen3:14b", digest: nil, size: 11_400_000_000, size_vram: 11_400_000_000,
                                    context_length: 16384, expires_at: soon),
                        runner: Runner(pid: 51877, port: 53114, blob: "", rssBytes: 10_900_000_000, cpu: 38, context: 16384)),
            LoadedModel(info: .init(name: "llama3.2:3b", digest: nil, size: 3_600_000_000, size_vram: 3_600_000_000,
                                    context_length: 8192, expires_at: far),
                        runner: Runner(pid: 51902, port: 53160, blob: "", rssBytes: 3_100_000_000, cpu: 0.2, context: 8192)),
        ]
        app.runnerCPU = 38.2
        app.runnerRSS = 14_000_000_000
        var brew = Server(engine: .ollama, pid: 3307, ports: [11500],
                          proc: proc(3307, 95_000_000, 0.1, "6-19:02:10", "/usr/local/opt/ollama/bin/ollama serve"),
                          management: .launchd("homebrew.mxcl.ollama"))
        brew.version = "0.32.15"
        brew.installed = ["mistral-nemo:12b"]
        var lms = Server(engine: .lmStudio, pid: 7741, ports: [1234],
                         proc: proc(7741, 6_200_000_000, 12.5, "41:08", "/Applications/LM Studio.app/Contents/MacOS/LM Studio --server"),
                         management: .manual)
        lms.apiModels = ["qwen2.5-coder-7b-instruct-mlx"]
        servers = [app, brew, lms]
    }

    func load(_ name: String, on s: Server, keepAlive: String = "30m", context: Int? = 16384) {
        guard let base = s.base else { return }
        run("model-\(s.pid)-\(name)", success: "\(name) loaded.") {
            Activity.log("Loading \(name) on port \(s.apiPort ?? 0) keep_alive=\(keepAlive) num_ctx=\(context ?? 0)")
            try await Ollama.load(name, at: base, keepAlive: keepAlive, context: context)
        }
    }
}
