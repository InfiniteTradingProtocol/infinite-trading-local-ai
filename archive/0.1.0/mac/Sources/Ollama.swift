import AppKit
import Foundation

// Everything that touches Ollama: its HTTP API, installing the official app,
// and letting the Infinite Trading site talk to it (OLLAMA_ORIGINS), exactly
// as the site's own setup guide does by hand.

enum Ollama {
    static let base = URL(string: "http://127.0.0.1:11434")!
    static let bundleID = "com.electron.ollama"
    static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    /// Developer ID team that signs the official Ollama app (Infra Technologies, Inc).
    static let teamID = "3MU9H2V9Y9"
    static let minMacOS = 14

    struct Installed: Decodable, Hashable {
        let name: String
        let size: Int64
    }

    struct PullProgress {
        var status: String
        var fraction: Double?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
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

    static func version() async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(for: request("api/version")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    static func tags() async -> [Installed] {
        struct Tags: Decodable { let models: [Installed]? }
        guard let (data, _) = try? await URLSession.shared.data(for: request("api/tags")),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models ?? []
    }

    /// Streams `/api/pull`. Cancelling the task stops the download; Ollama
    /// keeps the finished layers and resumes from them next time.
    static func pull(_ model: String, progress: @escaping (PullProgress) -> Void) async throws {
        let req = request("api/pull", method: "POST", body: ["model": model, "stream": true], timeout: 300)
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
        let (_, response) = try await URLSession.shared.data(for: request("api/delete", method: "DELETE", body: ["model": model]))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Couldn't remove \(model).") }
    }

    /// Asks Ollama the same question the browser does: is this origin allowed?
    static func allows(origin: String) async -> Bool {
        var r = request("api/version")
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

    /// Homebrew or a manual `ollama serve`: not managed by the app, so we can't restart it for the user.
    static var cliOnly: Bool {
        appURL == nil && ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var appRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

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

    static func launch(_ app: URL? = nil) async throws {
        guard let url = app ?? appURL else { throw Failure("Ollama isn't installed.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        guard await waitForServer(up: true, seconds: 30) else {
            throw Failure("Ollama opened but its server didn't start. Check the Ollama menu bar icon.")
        }
    }

    /// Quits and reopens the Ollama app so it picks up OLLAMA_ORIGINS.
    static func restart() async throws {
        guard appURL != nil else {
            throw Failure("Ollama is running outside the Ollama app (Homebrew or Terminal). Restart it yourself with OLLAMA_ORIGINS set.")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        if !(await waitForServer(up: false, seconds: 10)) {
            running.forEach { $0.forceTerminate() }
            _ = await waitForServer(up: false, seconds: 5)
        }
        try await launch()
    }

    @discardableResult
    static func waitForServer(up: Bool, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if (await version() != nil) == up { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}

// MARK: Site access (step 3 of the site's Ollama guide)

enum SiteAccess {
    static let origins = ["https://www.infinitetrading.io", "https://infinitetrading.io"]
    static let agentURL = URL(string: "https://www.infinitetrading.io/infinite-agent")!
    static let agentLabel = "io.infinitetrading.localai.ollama-origins"
    static var agentPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist")
    }

    static func current() -> [String] {
        shell("/bin/launchctl", ["getenv", "OLLAMA_ORIGINS"]).out
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Adds the site to whatever the user already allows; never removes entries.
    static func merged() -> String {
        var list = current()
        if list.contains("*") { return list.joined(separator: ",") }
        for o in origins where !list.contains(o) { list.append(o) }
        return list.joined(separator: ",")
    }

    /// `launchctl setenv` lasts until logout, so a LaunchAgent repeats it at login.
    static func apply() throws {
        let value = merged()
        guard shell("/bin/launchctl", ["setenv", "OLLAMA_ORIGINS", value]).status == 0 else {
            throw Ollama.Failure("macOS refused to set OLLAMA_ORIGINS.")
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/launchctl", "setenv", "OLLAMA_ORIGINS", value],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentPlist, options: .atomic)
    }

    /// Removes only what this app added.
    static func revoke() {
        let rest = current().filter { !origins.contains($0) }
        if rest.isEmpty {
            shell("/bin/launchctl", ["unsetenv", "OLLAMA_ORIGINS"])
        } else {
            shell("/bin/launchctl", ["setenv", "OLLAMA_ORIGINS", rest.joined(separator: ",")])
        }
        try? FileManager.default.removeItem(at: agentPlist)
    }

    static func allowed() async -> Bool { await Ollama.allows(origin: origins[0]) }
}

// MARK: Helpers

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
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
