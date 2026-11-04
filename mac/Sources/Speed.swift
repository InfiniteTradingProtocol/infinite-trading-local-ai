import Foundation

// Speed estimates: how fast a model will answer on this Mac.
//
// Generation (tokens/s) is memory-bandwidth bound: every new token reads the
// active weights once, plus a fixed per-token overhead, so
// seconds/token ≈ overhead + GB per token / effective bandwidth.
// Prompt processing is compute bound: tok/s ≈ effective FLOPS / (2 × active
// parameters). Both machine numbers start from a per-chip table and are
// replaced by a calibration when the user runs the speed test. Pure logic
// (no UI, no network) so tests/recommend can exercise it.

struct MachineSpeed: Codable, Equatable {
    /// Effective memory bandwidth for generation, GB/s.
    var bandwidthGBs: Double
    /// Effective compute for prompt processing, GFLOPS.
    var gflops: Double
    /// Fixed cost per generated token (scheduling, sampling, small kernels), seconds.
    var overheadS: Double? = nil
    /// "measured" after a speed test, otherwise "table".
    var source: String
    var measuredWith: String?
    var measuredAt: Date?
}

struct SpeedEstimate {
    let genTPS: Double
    let promptTPS: Double
    /// Seconds before the first word of a reply to the agent's typical first prompt.
    let firstReplySeconds: Double
    /// Seconds for a typical ~250-token answer (plus thinking for reasoning models).
    let answerSeconds: Double
    let measured: Bool

    enum Tier: Int, Comparable {
        case veryslow, slow, ok, fast
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    var tier: Tier {
        if genTPS < 3 || firstReplySeconds > 120 { return .veryslow }
        if genTPS < 7 || firstReplySeconds > 40 { return .slow }
        if genTPS < 15 { return .ok }
        return .fast
    }

    var label: String {
        let tps = genTPS >= 10 ? String(format: "%.0f", genTPS) : String(format: "%.1f", genTPS)
        return "\(measured ? "" : "≈ ")\(tps) tok/s"
    }

    var detail: String {
        "first reply \(duration(firstReplySeconds)) · answer \(duration(answerSeconds))"
    }

    var warning: String? {
        switch tier {
        case .veryslow:
            return "Very slow on this Mac: about \(label) and \(duration(answerSeconds)) for a typical answer. Choose a smaller model."
        case .slow:
            return "Slow on this Mac: expect \(duration(firstReplySeconds)) before the first word and \(duration(answerSeconds)) per answer."
        default:
            return nil
        }
    }
}

func duration(_ s: Double) -> String {
    if s < 1 { return "< 1 s" }
    if s < 90 { return "\(Int(s.rounded())) s" }
    if s < 3600 { return "\(Int((s / 60).rounded())) min" }
    return String(format: "%.1f h", s / 3600)
}

enum Speed {
    /// Tokens in the Infinite Agent's first prompt: core instructions, one or two
    /// skills and a page snapshot (~3k). Later turns reuse Ollama's prompt cache.
    static let agentPromptTokens = 3000.0
    static let answerTokens = 250.0
    /// Thinking tokens a reasoning model typically writes before answering.
    static let thinkingTokens = 600.0
    /// Share of theoretical bandwidth / FLOPS llama.cpp reaches on Apple GPUs
    /// (public llama.cpp Apple Silicon results: tg ≈ 0.45–0.7, pp ≈ 0.6–0.7).
    static let bandwidthEfficiency = 0.55
    static let computeEfficiency = 0.65

    /// Theoretical memory bandwidth (GB/s) and FP16 GPU TFLOPS per Apple chip.
    static let appleChips: [(name: String, bandwidth: Double, tflops: Double)] = [
        ("M1 Ultra", 800, 21), ("M1 Max", 400, 10.4), ("M1 Pro", 200, 5.2), ("M1", 68, 2.6),
        ("M2 Ultra", 800, 27), ("M2 Max", 400, 13.6), ("M2 Pro", 200, 6.8), ("M2", 100, 3.6),
        ("M3 Ultra", 819, 28), ("M3 Max", 400, 16.4), ("M3 Pro", 150, 7.4), ("M3", 100, 4.1),
        ("M4 Max", 546, 18.4), ("M4 Pro", 273, 9.2), ("M4", 120, 4.6),
        ("M5 Max", 600, 24), ("M5 Pro", 300, 12), ("M5", 153, 6),
    ]

    /// Starting point before a speed test. Intel Macs run models on the CPU;
    /// their defaults come from a measured i7-8700B (6 cores, DDR4-2666).
    static func table(for s: MacSpecs) -> MachineSpeed {
        guard s.appleSilicon else {
            return MachineSpeed(bandwidthGBs: intelBandwidth, gflops: intelGFLOPS, overheadS: intelOverhead, source: "table")
        }
        let chip = s.shortChip
        // Longest name first so "M3 Max" wins over "M3"; unknown future chips use the newest tier.
        let match = appleChips.sorted { $0.name.count > $1.name.count }.first { chip.hasPrefix($0.name) }
            ?? (chip.contains("Ultra") ? ("", 800, 27) : chip.contains("Max") ? ("", 546, 18.4)
                : chip.contains("Pro") ? ("", 273, 9.2) : ("", 120, 4.6))
        return MachineSpeed(bandwidthGBs: match.bandwidth * bandwidthEfficiency,
                            gflops: match.tflops * 1000 * computeEfficiency, overheadS: appleOverhead, source: "table")
    }

    /// Fitted to the i7-8700B benchmarks (1B–32B): 65 ms + GB / 17.3 GB/s per token, 315 GFLOPS prompt.
    static let intelBandwidth = 17.3
    static let intelGFLOPS = 315.0
    static let intelOverhead = 0.065
    static let appleOverhead = 0.008

    static func overhead(_ s: MacSpecs) -> Double { s.appleSilicon ? appleOverhead : intelOverhead }

    /// Bytes (GB) read per generated token: the whole model, or only the active experts.
    static func gbPerToken(_ m: ModelInfo) -> Double {
        guard let active = m.activeB, let total = m.paramsB, total > 0 else { return m.sizeGB }
        return m.sizeGB * active / total
    }

    static func estimate(_ m: ModelInfo, on s: MacSpecs, machine: MachineSpeed,
                         measured: Benchmark? = nil) -> SpeedEstimate {
        var gen: Double
        var pp: Double
        if let b = measured {
            gen = b.genTPS
            pp = b.promptTPS
        } else {
            let active = m.activeB ?? m.paramsB ?? m.sizeGB * 1.6
            gen = 1 / ((machine.overheadS ?? 0) + gbPerToken(m) / max(machine.bandwidthGBs, 0.1))
            pp = machine.gflops / (2 * active)
            // Part of the model spills to the CPU when it doesn't fit Metal's share.
            if s.appleSilicon && fit(m, on: s) == .ok {
                gen *= 0.45
                pp *= 0.35
            }
        }
        let first = agentPromptTokens / max(pp, 0.01)
        let think = m.reasoning ? thinkingTokens / max(gen, 0.01) : 0
        return SpeedEstimate(genTPS: gen, promptTPS: pp, firstReplySeconds: first,
                             answerSeconds: first + think + answerTokens / max(gen, 0.01),
                             measured: measured != nil)
    }

    /// Calibrates the machine from one measured model, keeping the chip's per-token overhead.
    static func calibrate(from b: Benchmark, model: ModelInfo?, sizeGB: Double, paramsB: Double,
                          overheadS: Double) -> MachineSpeed {
        let gb = model.map(gbPerToken) ?? sizeGB
        let active = model?.activeB ?? paramsB
        let perToken = max(1 / b.genTPS - overheadS, 0.001)
        return MachineSpeed(bandwidthGBs: gb / perToken, gflops: b.promptTPS * 2 * active, overheadS: overheadS,
                            source: "measured", measuredWith: b.model, measuredAt: b.at)
    }
}

/// One speed test result, as Ollama reports it.
struct Benchmark: Codable, Equatable {
    let model: String
    let genTPS: Double
    let promptTPS: Double
    let loadSeconds: Double
    let at: Date
}
