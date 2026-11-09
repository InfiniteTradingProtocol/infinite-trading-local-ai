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
    /// Speed of this Mac: per-chip table until a speed test calibrates it.
    @Published var machine: MachineSpeed
    /// Speed test results by installed model name.
    @Published var benchmarks: [String: Benchmark]
    @Published var benchmarking: String?

    private var poller: Task<Void, Never>?
    private static let machineKey = "machineSpeed", benchmarksKey = "benchmarks"

    init(catalog: Catalog? = nil) {
        let bundled = Bundle.main.url(forResource: "models", withExtension: "json").flatMap { try? Catalog.load(from: $0) }
        models = (catalog ?? bundled)?.models.sorted { $0.sizeGB < $1.sizeGB } ?? []
        let d = UserDefaults.standard
        let specs = MacSpecs.current()
        machine = d.data(forKey: Self.machineKey).flatMap { try? JSONDecoder().decode(MachineSpeed.self, from: $0) }
            ?? Speed.table(for: specs)
        benchmarks = d.data(forKey: Self.benchmarksKey)
            .flatMap { try? JSONDecoder().decode([String: Benchmark].self, from: $0) } ?? [:]
    }

    var installedNames: Set<String> { Set(installed.map(\.name)) }
    var recommended: ModelInfo? {
        recommend(models, for: specs, installed: installedNames, speed: estimate)
    }

    // MARK: Speed

    func measured(_ m: ModelInfo) -> Benchmark? { m.names.compactMap { benchmarks[$0] }.first }

    func estimate(_ m: ModelInfo) -> SpeedEstimate {
        Speed.estimate(m, on: specs, machine: machine, measured: measured(m))
    }

    /// Installed models that aren't in the catalog (pulled by hand or by other apps).
    var otherInstalled: [Ollama.Installed] {
        let known = Set(models.flatMap(\.names))
        return installed.filter { !known.contains($0.name) && !$0.name.contains("embed") }
    }

    /// Catalog-shaped stand-in so speed and fit work for any installed model.
    func info(for i: Ollama.Installed) -> ModelInfo {
        ModelInfo(id: i.name, aliases: [], name: i.name, params: i.details?.parameter_size ?? "?",
                  paramsB: i.paramsB, activeB: nil, publisher: "", sizeGB: Double(i.size) / 1e9,
                  minRAM: 0, recRAM: 0, context: 0, rank: 0, tags: [], summary: "")
    }

    /// Runs Ollama's own timers on a real model, then recalibrates every estimate.
    /// With no name, tests a mid-size installed model (small ones understate bandwidth).
    func speedTest(_ name: String? = nil) async {
        let chat = installed.filter { !$0.name.contains("embed") }.sorted { $0.size < $1.size }
        guard let pick = name.flatMap({ n in chat.first { $0.name == n } })
                ?? chat.first(where: { $0.size >= 1_800_000_000 }) ?? chat.first else {
            error = "Download a model first, then run the speed test."
            return
        }
        benchmarking = pick.name
        defer { benchmarking = nil }
        // Other work on the CPU/GPU slows the test down; say so instead of trusting it blindly.
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let busy = load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) * 0.5
        Activity.log(String(format: "Speed test: %@ (load average %.1f)", pick.name, load[0]))
        do {
            let fresh = try await Ollama.benchmark(pick.name)
            // Keep the fastest run per model: a slower one usually means the Mac was busy.
            let previous = benchmarks[pick.name]
            let b = previous.map { $0.genTPS >= fresh.genTPS ? $0 : fresh } ?? fresh
            benchmarks[pick.name] = b
            let catalogModel = models.first { $0.names.contains(pick.name) }
            machine = Speed.calibrate(from: b, model: catalogModel, sizeGB: Double(pick.size) / 1e9,
                                      paramsB: pick.paramsB ?? Double(pick.size) / 1e9 * 1.6,
                                      overheadS: Speed.overhead(specs))
            let d = UserDefaults.standard
            d.set(try? JSONEncoder().encode(machine), forKey: Self.machineKey)
            d.set(try? JSONEncoder().encode(benchmarks), forKey: Self.benchmarksKey)
            var msg = String(format: "%@: %.1f tok/s writing, %.0f tok/s reading the prompt.",
                             pick.name, fresh.genTPS, fresh.promptTPS)
            if b != fresh {
                msg += String(format: " Kept your faster earlier result (%.1f tok/s) for the estimates.", b.genTPS)
            } else {
                msg += " Estimates now use this Mac's measured speed."
            }
            if busy {
                msg += " Your Mac was busy during the test, so this is lower than its best; run it again when it's idle."
            }
            notice = msg
            Activity.log(String(format: "Speed test %@: gen %.2f tok/s, prompt %.1f tok/s, load %.1f s%@",
                                pick.name, fresh.genTPS, fresh.promptTPS, fresh.loadSeconds, busy ? " (Mac busy)" : ""))
        } catch {
            self.error = "Speed test failed: \(error.localizedDescription)"
        }
    }
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

    func remove(name: String) async {
        Activity.log("Removing \(name)")
        do { try await Ollama.delete(name) } catch { self.error = error.localizedDescription }
        benchmarks[name] = nil
        await refresh()
    }

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
                error = "Ollama restarted but still blocks the site. Stop Ollama in the Running tab, start it again, then press Check."
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
