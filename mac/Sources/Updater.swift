import AppKit
import CryptoKit
import Foundation

// Finds, verifies and installs new versions of the app.
//
// Sources, first that answers wins:
//   1. GitHub releases API (anonymous).
//   2. infinitetrading.io/downloads/latest.json: the site's copy of the release.
//   3. The GitHub CLI (`gh`) signed in on this Mac: a fallback when the anonymous
//      API is rate-limited or blocked.
// Every download must match the release's SHA-256, carry a valid signature,
// the same bundle id (and Developer ID team, once signed) and a higher version.
// The running app is never overwritten in place: a helper script waits for it
// to quit, moves it to the Trash, copies the new one in and relaunches it.

struct UpdateAsset {
    let arch: String // universal | apple-silicon | intel
    let name: String
    let url: URL?
    let sha256: String?
}

struct AvailableUpdate {
    enum Source: String { case github = "GitHub", site = "infinitetrading.io", ghCLI = "GitHub (your gh login)" }
    let version: String
    let tag: String
    let notes: String
    let assets: [UpdateAsset]
    let source: Source

    /// This Mac's single-architecture DMG, else the universal one.
    var bestAsset: UpdateAsset? {
        assets.first { $0.arch == Updater.thisArch } ?? assets.first { $0.arch == "universal" } ?? assets.first
    }
}

enum Updater {
    static let repo = "InfiniteTradingProtocol/infinite-trading-local-ai"
    static let manifestURL = URL(string: "https://www.infinitetrading.io/downloads/latest.json")!
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var thisArch: String {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1 ? "apple-silicon" : "intel"
    }
    static var workDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.infinitetrading.agentmanager/updates")
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// "0.10.0" > "0.9.3"; ignores a leading "v".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let p = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (p(a), p(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    static func arch(of name: String) -> String {
        name.hasSuffix("-apple-silicon.dmg") ? "apple-silicon" : name.hasSuffix("-intel.dmg") ? "intel" : "universal"
    }

    // MARK: Sources

    private struct GhRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    private static func fromGitHub(_ r: GhRelease, source: AvailableUpdate.Source) -> AvailableUpdate {
        let assets = r.assets.filter { $0.name.hasSuffix(".dmg") }.map {
            UpdateAsset(arch: arch(of: $0.name), name: $0.name, url: URL(string: $0.browser_download_url),
                        sha256: $0.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
        }
        return AvailableUpdate(version: r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                               tag: r.tag_name, notes: r.body ?? "", assets: assets, source: source)
    }

    private static func get(_ url: URL) async -> Data? {
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        r.setValue("InfiniteAgentManager/\(current)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json, application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Latest release from the first source that answers, plus why the others didn't.
    static func latest() async -> (AvailableUpdate?, [String]) {
        var notes: [String] = []
        if let d = await get(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!),
           let r = try? JSONDecoder().decode(GhRelease.self, from: d) {
            return (fromGitHub(r, source: .github), notes)
        }
        notes.append("GitHub: not reachable")

        struct Manifest: Decodable {
            struct File: Decodable { let arch: String; let file: String; let url: String; let sha256: String }
            let version: String; let tag: String; let notes: String?; let files: [File]
        }
        if let d = await get(manifestURL), let m = try? JSONDecoder().decode(Manifest.self, from: d) {
            let assets = m.files.map {
                UpdateAsset(arch: $0.arch, name: $0.file,
                            url: URL(string: $0.url, relativeTo: manifestURL)?.absoluteURL, sha256: $0.sha256)
            }
            return (AvailableUpdate(version: m.version, tag: m.tag, notes: m.notes ?? "", assets: assets, source: .site), notes)
        }
        notes.append("infinitetrading.io: not reachable from the app")

        if let gh = ghPath {
            let r = await Task.detached { shell(gh, ["api", "repos/\(repo)/releases/latest"]) }.value
            if r.status == 0, let rel = try? JSONDecoder().decode(GhRelease.self, from: Data(r.out.utf8)) {
                return (fromGitHub(rel, source: .ghCLI), notes)
            }
            notes.append("gh: not signed in to an account that can see the repository")
        } else {
            notes.append("gh: not installed")
        }
        return (nil, notes)
    }

    // MARK: Download, verify, stage

    static func download(_ u: AvailableUpdate, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let asset = u.bestAsset else { throw Failure("The release has no macOS download.") }
        guard let expected = asset.sha256?.lowercased(), expected.count == 64 else {
            throw Failure("The release doesn't publish a SHA-256 for \(asset.name), so it wasn't installed.")
        }
        let dir = workDir.appendingPathComponent(u.version)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent(asset.name)
        if u.source == .ghCLI, let gh = ghPath {
            let r = await Task.detached {
                shell(gh, ["release", "download", u.tag, "-R", repo, "-p", asset.name, "-D", dir.path, "--clobber"])
            }.value
            guard r.status == 0 else { throw Failure("gh couldn't download \(asset.name): \(r.err.prefix(160))") }
        } else if let url = asset.url {
            try await Downloader.fetch(url, to: dmg, progress: progress)
        } else {
            throw Failure("No download address for \(asset.name).")
        }
        let got = try sha256(of: dmg)
        guard got == expected else {
            try? FileManager.default.removeItem(at: dmg)
            throw Failure("\(asset.name) doesn't match the published SHA-256 (got \(got.prefix(12))…), so it was deleted.")
        }
        return dmg
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func teamID(_ app: URL) -> String? {
        let r = shell("/usr/bin/codesign", ["-dv", app.path])
        return (r.out + r.err).split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }.flatMap { $0 == "not set" ? nil : $0 }
    }

    /// Mounts the DMG, checks the app inside, copies it out. Returns the staged app.
    static func stage(_ dmg: URL, version: String) throws -> URL {
        let mnt = dmg.deletingLastPathComponent().appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        guard shell("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mnt.path, dmg.path]).status == 0 else {
            throw Failure("Couldn't open the downloaded disk image.")
        }
        defer { shell("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mnt.path]) }
        guard let src = try FileManager.default.contentsOfDirectory(at: mnt, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: src.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure("The disk image doesn't contain the app.")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Failure("The downloaded app has a different identity, so it wasn't installed.")
        }
        guard info["CFBundleShortVersionString"] as? String == version, isNewer(version, than: current) else {
            throw Failure("The downloaded app isn't version \(version).")
        }
        guard shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", src.path]).status == 0 else {
            throw Failure("The downloaded app's signature is broken, so it wasn't installed.")
        }
        if let mine = teamID(Bundle.main.bundleURL), teamID(src) != mine {
            throw Failure("The downloaded app isn't signed by the same developer, so it wasn't installed.")
        }
        let staged = dmg.deletingLastPathComponent().appendingPathComponent("staged/\(src.lastPathComponent)")
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard shell("/usr/bin/ditto", [src.path, staged.path]).status == 0 else { throw Failure("Couldn't copy the new app.") }
        try? FileManager.default.removeItem(at: dmg) // the staged app is all that's needed now
        return staged
    }

    /// Removes downloads, staged apps and the install helper left by past updates.
    /// Safe at launch: nothing is staged yet, and a running helper has already
    /// copied its app (the shell keeps its open script after the file is gone).
    static func cleanUp() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil), !items.isEmpty else { return }
        let size = items.reduce(0) { $0 + du($1) }
        try? fm.removeItem(at: workDir)
        Activity.log(String(format: "Cleared the update cache (%.0f MB)", Double(size) / 1e6))
    }

    private static func du(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    /// Where the running app can be replaced: not on a disk image, in a writable folder.
    static var installBlocker: String? {
        let target = Bundle.main.bundleURL
        if target.path.hasPrefix("/Volumes/") { return "Move the app to Applications first; it's running from a disk image." }
        if !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            return "This account can't write to \(target.deletingLastPathComponent().path)."
        }
        return nil
    }

    /// Hands over to a helper that swaps the app once this process exits, then quits.
    @MainActor
    static func installAndRelaunch(_ staged: URL, background: Bool) throws {
        if let b = installBlocker { throw Failure(b) }
        let script = workDir.appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        # Infinite Agent Manager updater: wait for the old app to quit, swap, relaunch.
        pid="$1"; target="$2"; staged="$3"; bg="$4"
        i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
        trash="$HOME/.Trash/$(basename "$target" .app) $(date +%Y%m%d-%H%M%S).app"
        if mv "$target" "$trash" && /usr/bin/ditto "$staged" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        else
          [ -d "$target" ] || mv "$trash" "$target"
        fi
        if [ "$bg" = "1" ]; then /usr/bin/open -g "$target"; else /usr/bin/open "$target"; fi
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(getpid()), Bundle.main.bundleURL.path, staged.path, background ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        Activity.log("Installing update from \(staged.path); relaunching")
        NSApp.terminate(nil)
    }
}

// MARK: State

@MainActor
final class UpdateModel: ObservableObject {
    @Published var status = "Not checked yet"
    @Published var available: AvailableUpdate?
    @Published var staged: URL?
    @Published var progress: Double?
    @Published var busy = false
    @Published var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "autoInstallUpdates") }
    }
    /// The app is doing something an update restart would interrupt.
    var isBusyElsewhere: () -> Bool = { false }
    private var timer: Task<Void, Never>?

    init() {
        autoInstall = UserDefaults.standard.object(forKey: "autoInstallUpdates") as? Bool ?? true
    }

    var current: String { Updater.current }

    func start() {
        guard timer == nil else { return }
        Updater.cleanUp()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.installIfQuiet() }
        }
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = "Checking for updates…"
        let (u, why) = await Updater.latest()
        guard let u else {
            status = "Couldn't check: " + why.joined(separator: "; ")
            return
        }
        guard Updater.isNewer(u.version, than: current) else {
            let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            status = "Up to date · checked \(t) via \(u.source.rawValue)"
            available = nil
            return
        }
        available = u
        if staged != nil { return }
        status = "Downloading \(u.version)…"
        Activity.log("Update \(u.version) found via \(u.source.rawValue)")
        do {
            let dmg = try await Updater.download(u) { p in Task { @MainActor in self.progress = p } }
            progress = nil
            staged = try Updater.stage(dmg, version: u.version)
            status = "Version \(u.version) is ready to install"
            Activity.log("Update \(u.version) downloaded and verified (SHA-256, signature, identity)")
            if userInitiated == false { installIfQuiet() }
        } catch {
            progress = nil
            try? FileManager.default.removeItem(at: Updater.workDir.appendingPathComponent(u.version))
            status = "Update failed: \(error.localizedDescription)"
            Activity.log("Update failed: \(error.localizedDescription)")
        }
    }

    /// Auto-install only when the window isn't in use and nothing is running.
    func installIfQuiet() {
        guard autoInstall, let staged, !NSApp.isActive, !isBusyElsewhere() else { return }
        try? Updater.installAndRelaunch(staged, background: true)
    }

    func installNow() {
        guard let staged else { return }
        do { try Updater.installAndRelaunch(staged, background: false) } catch { status = error.localizedDescription }
    }
}
