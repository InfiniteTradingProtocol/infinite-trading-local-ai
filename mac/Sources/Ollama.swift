import AppKit
import Foundation

// Everything that touches Ollama: its HTTP API, installing the official app,
// its launchd environment (OLLAMA_ORIGINS, OLLAMA_HOST) and restarting it.
// API calls take the server's base URL because several servers can run at
// once (the app on one port, Homebrew on another).

enum Ollama {
    static let defaultPort = 11434
    /// Port of the server this app sets up and connects the site to; follows OLLAMA_HOST.
    static var port = OllamaEnv.configuredPort()
    static var base: URL { url(port: port) }
    static func url(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    static let bundleID = "com.electron.ollama"
    static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    /// Developer ID team that signs the official Ollama app (Infra Technologies, Inc).
    static let teamID = "3MU9H2V9Y9"
    static let minMacOS = 14

    struct Installed: Decodable, Hashable {
        let name: String
        let size: Int64
    }

    struct Loaded: Decodable, Hashable {
        let name: String
        let digest: String?
        let size: Int64
        let size_vram: Int64?
        let context_length: Int?
        let expires_at: String?

        var gpuShare: Double { size > 0 ? Double(size_vram ?? 0) / Double(size) : 0 }
        var expires: Date? {
            guard let s = expires_at else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
        }
    }

    struct PullProgress {
        var status: String
        var fraction: Double?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func request(_ path: String, at base: URL, method: String = "GET", body: [String: Any]? = nil,
                                timeout: TimeInterval = 3) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private static func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure("Ollama: \(msg ?? "HTTP \(code)")")
        }
        return data
    }

    static func version(at base: URL = base) async -> String? {
        guard let data = try? await send(request("api/version", at: base)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    static func tags(at base: URL = base) async -> [Installed] {
        struct Tags: Decodable { let models: [Installed]? }
        guard let data = try? await send(request("api/tags", at: base)),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models ?? []
    }

    static func loaded(at base: URL) async -> [Loaded] {
        struct PS: Decodable { let models: [Loaded]? }
        guard let data = try? await send(request("api/ps", at: base)),
              let ps = try? JSONDecoder().decode(PS.self, from: data) else { return [] }
        return ps.models ?? []
    }

    /// The model's weights blob, used to match a loaded model to its runner process.
    static func blob(of model: String, at base: URL) async -> String? {
        guard let data = try? await send(request("api/show", at: base, method: "POST", body: ["model": model], timeout: 10)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = obj["modelfile"] as? String,
              let from = file.split(separator: "\n").first(where: { $0.hasPrefix("FROM ") }) else { return nil }
        return URL(fileURLWithPath: String(from.dropFirst(5))).lastPathComponent
    }

    /// Loads a model into memory without generating (empty prompt).
    static func load(_ model: String, at base: URL, keepAlive: String, context: Int?) async throws {
        var body: [String: Any] = ["model": model, "keep_alive": keepAlive]
        if let context { body["options"] = ["num_ctx": context] }
        _ = try await send(request("api/generate", at: base, method: "POST", body: body, timeout: 600))
    }

    static func unload(_ model: String, at base: URL) async throws {
        _ = try await send(request("api/generate", at: base, method: "POST", body: ["model": model, "keep_alive": 0], timeout: 60))
        for _ in 0..<20 {
            if !(await loaded(at: base).contains { $0.name == model }) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Streams `/api/pull`. Cancelling the task stops the download; Ollama
    /// keeps the finished layers and resumes from them next time.
    static func pull(_ model: String, progress: @escaping (PullProgress) -> Void) async throws {
        let req = request("api/pull", at: base, method: "POST", body: ["model": model, "stream": true], timeout: 300)
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Ollama refused to download \(model).")
        }
        var layers: [String: (total: Double, done: Double)] = [:]
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw Failure("Ollama: \(error)") }
            let status = obj["status"] as? String ?? ""
            if let digest = obj["digest"] as? String, let total = obj["total"] as? Double, total > 0 {
                layers[digest] = (total, obj["completed"] as? Double ?? layers[digest]?.done ?? 0)
            }
            let total = layers.values.reduce(0) { $0 + $1.total }
            let done = layers.values.reduce(0) { $0 + $1.done }
            let fraction = total > 0 ? done / total : nil
            let text = status.hasPrefix("pulling ") && fraction != nil
                ? "Downloading \(formatGB(done / 1e9)) of \(formatGB(total / 1e9))"
                : status.prefix(1).uppercased() + status.dropFirst()
            progress(PullProgress(status: text, fraction: status == "success" ? 1 : fraction))
            if status == "success" { return }
        }
        throw Failure("The download stopped before it finished. Try again to resume.")
    }

    static func delete(_ model: String) async throws {
        _ = try await send(request("api/delete", at: base, method: "DELETE", body: ["model": model]))
    }

    /// Asks Ollama the same question the browser does: is this origin allowed?
    static func allows(origin: String, at base: URL = base) async -> Bool {
        var r = request("api/version", at: base)
        r.setValue(origin, forHTTPHeaderField: "Origin")
        guard let (_, response) = try? await URLSession.shared.data(for: r),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") != nil
    }

    // MARK: App install and lifecycle

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        return ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var cliPath: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Homebrew or a manual `ollama serve`, without the desktop app.
    static var cliOnly: Bool { appURL == nil && cliPath != nil }

    /// Downloads the official app, checks it is notarized and signed by
    /// Ollama's team, then moves it into Applications and opens it.
    static func install(progress: @escaping (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("Ollama.zip")
        try await Downloader.fetch(downloadURL, to: zip, progress: progress)
        let unzip = shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let staged = work.appendingPathComponent("Ollama.app")
        guard unzip.status == 0, FileManager.default.fileExists(atPath: staged.path) else {
            throw Failure("The Ollama download was damaged. Please try again.")
        }
        try verify(staged)

        let system = URL(fileURLWithPath: "/Applications")
        let parent = FileManager.default.isWritableFile(atPath: system.path)
            ? system : URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Ollama.app")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staged, to: target)
        Activity.log("Installed Ollama at \(target.path)")
        try await launch(target)
    }

    static func verify(_ app: URL) throws {
        let strict = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = shell("/usr/bin/codesign", ["-dv", app.path])
        let gatekeeper = shell("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard strict.status == 0, gatekeeper.status == 0,
              (info.out + info.err).contains("TeamIdentifier=\(teamID)") else {
            throw Failure("The downloaded Ollama app isn't signed by Ollama, so it wasn't installed.")
        }
    }

    static func launch(_ app: URL? = nil, port: Int = port) async throws {
        guard let url = app ?? appURL else { throw Failure("Ollama isn't installed.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        guard await waitForServer(at: Ollama.url(port: port), up: true, seconds: 30) else {
            throw Failure("Ollama opened but its server didn't answer on port \(port). Check the Ollama menu bar icon.")
        }
    }

    /// Quits and reopens the Ollama desktop app so it picks up its environment.
    static func restartApp(port: Int = port, newPort: Int? = nil) async throws {
        guard appURL != nil else { throw Failure("The Ollama app isn't installed.") }
        await quitApp(port: port)
        try await launch(port: newPort ?? port)
    }

    /// Quits the Ollama app, force-quitting it if its server is still up after 8 s.
    static func quitApp(port: Int = port) async {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        if !(await waitForServer(at: url(port: port), up: false, seconds: 8)) {
            running.forEach { $0.forceTerminate() }
            _ = await waitForServer(at: url(port: port), up: false, seconds: 5)
        }
    }

    /// Restarts whichever server owns the main port (used after changing OLLAMA_ORIGINS).
    static func restart() async throws {
        if let server = Discovery.scan().first(where: { $0.engine == .ollama && $0.ports.contains(port) }) {
            try await Control.restart(server)
        } else if appURL != nil {
            try await launch()
        } else {
            throw Failure("Ollama isn't running on port \(port).")
        }
    }

    @discardableResult
    static func waitForServer(at base: URL = base, up: Bool, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if (await version(at: base) != nil) == up { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}

// MARK: launchd environment for Ollama

/// `launchctl setenv` lasts until logout, so one LaunchAgent re-applies the
/// variables this app manages at login.
enum OllamaEnv {
    static let keys = ["OLLAMA_ORIGINS", "OLLAMA_HOST"]
    static let agentLabel = "io.infinitetrading.agentmanager.ollama-env"
    static let legacyLabels = ["io.infinitetrading.localai.ollama-origins"]

    static func plist(_ label: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    static func get(_ key: String) -> String {
        shell("/bin/launchctl", ["getenv", key]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ key: String, _ value: String?) throws {
        let args = value.map { ["setenv", key, $0] } ?? ["unsetenv", key]
        let ok = shell("/bin/launchctl", args).status == 0
        guard ok else { throw Ollama.Failure("macOS refused to set \(key).") }
        try persist()
    }

    /// Port from OLLAMA_HOST ("0.0.0.0", "127.0.0.1:11435", "http://localhost:8081", ":11500").
    static func configuredPort() -> Int {
        let host = get("OLLAMA_HOST")
        guard let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return Ollama.defaultPort }
        return p
    }

    static func persist() throws {
        for legacy in legacyLabels { try? FileManager.default.removeItem(at: plist(legacy)) }
        let pairs = keys.map { ($0, get($0)) }.filter { !$0.1.isEmpty }
        let target = plist(agentLabel)
        if pairs.isEmpty { try? FileManager.default.removeItem(at: target); return }
        let script = pairs.map { "/bin/launchctl setenv \($0.0) \(quoted($0.1))" }.joined(separator: "; ")
        let dict: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/sh", "-c", script],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: Site access (step 3 of the site's Ollama guide)

enum SiteAccess {
    static let origins = ["https://www.infinitetrading.io", "https://infinitetrading.io"]
    static let agentURL = URL(string: "https://www.infinitetrading.io/infinite-agent")!

    static func current() -> [String] {
        OllamaEnv.get("OLLAMA_ORIGINS")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds the site to whatever the user already allows; never removes entries.
    static func apply() throws {
        var list = current()
        if list.contains("*") { return }
        for o in origins where !list.contains(o) { list.append(o) }
        try OllamaEnv.set("OLLAMA_ORIGINS", list.joined(separator: ","))
        Activity.log("Allowed \(origins.joined(separator: ", ")) in OLLAMA_ORIGINS")
    }

    /// Removes only what this app added.
    static func revoke() {
        let rest = current().filter { !origins.contains($0) }
        try? OllamaEnv.set("OLLAMA_ORIGINS", rest.isEmpty ? nil : rest.joined(separator: ","))
        Activity.log("Removed Infinite Trading from OLLAMA_ORIGINS")
    }

    static func allowed() async -> Bool { await Ollama.allows(origin: origins[0]) }
}

// MARK: Helpers

@discardableResult
func shell(_ path: String, _ args: [String], env: [String: String]? = nil) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

/// URLSession download with progress, bridged to async.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: (Double) -> Void

    private init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let d = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.continuation = c
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(Ollama.Failure("Couldn't download Ollama (HTTP \(status)).")); return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
