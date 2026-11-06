import AppKit
import Foundation

enum OllamaState: Equatable {
    case checking, notInstalled, stopped, running(String)
}

struct Job {
    var status: String
    var fraction: Double?
    var task: Task<Void, Never>?
}

@MainActor
final class AppModel: ObservableObject {
    let specs = MacSpecs.current()
    let models: [ModelInfo]

    @Published var ollama: OllamaState = .checking
    @Published var installed: [Ollama.Installed] = []
    @Published var siteAllowed = false
    @Published var pulls: [String: Job] = [:]
    @Published var ollamaJob: Job?
    @Published var connecting = false
    @Published var error: String?
    @Published var notice: String?

    private var poller: Task<Void, Never>?

    init(catalog: Catalog? = nil) {
        let bundled = Bundle.main.url(forResource: "models", withExtension: "json").flatMap { try? Catalog.load(from: $0) }
        models = (catalog ?? bundled)?.models.sorted { $0.sizeGB < $1.sizeGB } ?? []
    }

    var installedNames: Set<String> { Set(installed.map(\.name)) }
    var recommended: ModelInfo? { recommend(models, for: specs, installed: installedNames) }
    var running: Bool { if case .running = ollama { return true } else { return false } }
    var hasModel: Bool { !installed.filter { !$0.name.contains("embed") }.isEmpty }
    var ready: Bool { running && hasModel && siteAllowed }
    var osTooOld: Bool { specs.osMajor < Ollama.minMacOS }

    func isInstalled(_ m: ModelInfo) -> Bool { !m.names.isDisjoint(with: installedNames) }
    func installedSize(_ m: ModelInfo) -> Double? {
        installed.first { m.names.contains($0.name) }.map { Double($0.size) / 1e9 }
    }

    // MARK: Polling

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func refresh() async {
        if let v = await Ollama.version() {
            ollama = .running(v)
            installed = await Ollama.tags()
            siteAllowed = await SiteAccess.allowed()
        } else if ollamaJob == nil {
            ollama = Ollama.appURL != nil || Ollama.cliOnly ? .stopped : .notInstalled
            siteAllowed = false
        }
    }

    // MARK: Steps

    func installOllama() async -> Bool {
        if running { return true }
        ollamaJob = Job(status: Ollama.appURL == nil ? "Downloading Ollama" : "Starting Ollama", fraction: nil)
        defer { ollamaJob = nil }
        do {
            if Ollama.appURL == nil {
                try await Ollama.install { p in
                    Task { @MainActor in self.ollamaJob?.fraction = p }
                }
            } else {
                try await Ollama.launch()
            }
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func download(_ m: ModelInfo) async -> Bool {
        if !running { guard await installOllama() else { return false } }
        if isInstalled(m) { return true }
        let task = Task { [weak self] in
            do {
                try await Ollama.pull(m.id) { p in
                    Task { @MainActor in
                        self?.pulls[m.id]?.status = p.status
                        self?.pulls[m.id]?.fraction = p.fraction
                    }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
        }
        pulls[m.id] = Job(status: "Starting download", fraction: nil, task: task)
        Activity.log("Downloading \(m.id)")
        await task.value
        pulls[m.id] = nil
        await refresh()
        return isInstalled(m)
    }

    func cancel(_ m: ModelInfo) { pulls[m.id]?.task?.cancel() }

    func remove(_ m: ModelInfo) async {
        for name in installedNames where m.names.contains(name) {
            Activity.log("Removing \(name)")
            do { try await Ollama.delete(name) } catch { self.error = error.localizedDescription }
        }
        await refresh()
    }

    func connectSite() async -> Bool {
        connecting = true
        defer { connecting = false }
        do {
            try SiteAccess.apply()
            if !(await SiteAccess.allowed()) { try await Ollama.restart() }
            await refresh()
            if !siteAllowed {
                error = "Ollama restarted but still blocks the site. Quit Ollama from the menu bar, open it again, then press Check."
            }
            return siteAllowed
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnectSite() async {
        SiteAccess.revoke()
        if running { try? await Ollama.restart() }
        await refresh()
    }

    /// The one-click path: Ollama → model → site access → open the agent.
    func setUp(_ m: ModelInfo) async {
        error = nil
        guard await installOllama(), await download(m) else { return }
        if !siteAllowed { guard await connectSite() else { return } }
        notice = "\(m.title) is ready. Open the Infinite Agent and choose Ollama."
        openAgent()
    }

    func openAgent() { NSWorkspace.shared.open(SiteAccess.agentURL) }
}
