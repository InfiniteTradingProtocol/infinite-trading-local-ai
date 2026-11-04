import Foundation

// Model catalog, Mac specs and the fit/recommendation rules. No UI or network
// here so tests/recommend-test.swift can compile it on its own.

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let aliases: [String]
    let name: String
    let params: String
    /// Parameters in billions; activeB is set for mixture-of-experts models (per-token).
    let paramsB: Double?
    let activeB: Double?
    let publisher: String
    let sizeGB: Double
    let minRAM: Double
    let recRAM: Double
    let context: Int
    let rank: Int
    let tags: [String]
    let summary: String

    var title: String { "\(name) \(params)" }
    var names: Set<String> { Set([id] + aliases) }
    var reasoning: Bool { tags.contains("reasoning") }
}

struct Catalog: Codable {
    let version: Int
    let models: [ModelInfo]

    static func load(from url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }
}

struct MacSpecs {
    let chip: String
    let appleSilicon: Bool
    let memoryGB: Double
    let freeDiskGB: Double
    let osMajor: Int
    let osVersion: String

    static func current() -> MacSpecs {
        // ILA_SPECS="M3 Pro,36" previews another Mac (snapshots and docs only).
        if let fake = ProcessInfo.processInfo.environment["ILA_SPECS"]?.split(separator: ","), fake.count == 2,
           let ram = Double(fake[1]) {
            return MacSpecs(chip: "Apple \(fake[0])", appleSilicon: fake[0].hasPrefix("M"), memoryGB: ram,
                            freeDiskGB: 412, osMajor: 15, osVersion: "15.7")
        }
        let arm = sysctlInt("hw.optional.arm64") == 1
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var free = 0.0
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            free = Double(cap) / 1e9
        }
        return MacSpecs(
            chip: sysctlString("machdep.cpu.brand_string") ?? (arm ? "Apple Silicon" : "Intel"),
            appleSilicon: arm,
            memoryGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded(),
            freeDiskGB: free,
            osMajor: v.majorVersion,
            osVersion: "\(v.majorVersion).\(v.minorVersion)"
        )
    }

    /// "Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz" → "Intel Core i7-8700"; "Apple M3 Pro" → "M3 Pro".
    var shortChip: String {
        var c = chip
        for junk in ["(R)", "(TM)", "Apple "] { c = c.replacingOccurrences(of: junk, with: "") }
        if let at = c.range(of: " CPU") ?? c.range(of: " @") { c = String(c[..<at.lowerBound]) }
        return c.trimmingCharacters(in: .whitespaces)
    }

    /// Unified memory Metal will give a model: about two thirds on smaller
    /// Macs, three quarters above 36 GB. Intel Macs run models on the CPU.
    var gpuBudgetGB: Double {
        appleSilicon ? memoryGB * (memoryGB > 36 ? 0.75 : 0.66) : memoryGB * 0.5
    }
}

enum Fit: Int, Comparable {
    case noDisk, tooLarge, tooSlow, slow, ok, great

    static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .great: return "Great fit"
        case .ok: return "Runs, slower"
        case .slow: return "Slow on this Mac"
        case .tooSlow: return "Too slow here"
        case .tooLarge: return "Too large"
        case .noDisk: return "Not enough disk"
        }
    }
}

func fit(_ m: ModelInfo, on s: MacSpecs, installed: Bool = false) -> Fit {
    if !installed && s.freeDiskGB < m.sizeGB + 2 { return .noDisk }
    if s.memoryGB < m.minRAM { return .tooLarge }
    if !s.appleSilicon {
        // No GPU offload on Intel Macs: only small models that answer
        // without a long thinking pass stay responsive.
        if m.sizeGB <= 2.6 && !m.reasoning && s.memoryGB >= m.recRAM { return .great }
        return m.sizeGB <= 10 ? .slow : .tooSlow
    }
    // Great = weights plus ~1.5 GB of 16k-context KV cache fit in Metal's share.
    return s.memoryGB >= m.recRAM && m.sizeGB + 1.5 <= s.gpuBudgetGB ? .great : .ok
}

/// Highest-ranked model that fits fully; falls back to the best that runs.
/// With a speed estimator, a model that fits but would be very slow here
/// (under 3 tok/s, or minutes before the first word) is passed over.
func recommend(_ models: [ModelInfo], for s: MacSpecs, installed: Set<String> = [],
               speed: ((ModelInfo) -> SpeedEstimate)? = nil) -> ModelInfo? {
    let scored = models.map { ($0, fit($0, on: s, installed: !$0.names.isDisjoint(with: installed))) }
    for wanted in [Fit.great, .ok, .slow] {
        let pool = scored.filter { $0.1 == wanted }.map(\.0)
        guard !pool.isEmpty else { continue }
        // Skip models that would be very slow here, but keep "slow" ones: on an
        // Intel CPU a readable 3B beats a fast but much weaker 1B.
        if let speed, let best = pool.filter({ speed($0).tier > .veryslow }).max(by: { $0.rank < $1.rank }) {
            return best
        }
        return pool.max { $0.rank < $1.rank }
    }
    return nil
}

func formatGB(_ gb: Double) -> String {
    gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

private func sysctlInt(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
}
