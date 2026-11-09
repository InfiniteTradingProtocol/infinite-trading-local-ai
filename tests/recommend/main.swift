// swiftc -swift-version 5 mac/Sources/{Catalog,Speed}.swift tests/recommend/main.swift -o build/recommend-test && build/recommend-test
import Foundation

let catalog = try! Catalog.load(from: URL(fileURLWithPath: "catalog/models.json"))
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

func mac(_ ram: Double, arm: Bool = true, disk: Double = 500, chip: String = "test") -> MacSpecs {
    MacSpecs(chip: chip, appleSilicon: arm, memoryGB: ram, freeDiskGB: disk, osMajor: 15, osVersion: "15.0")
}

let ids = catalog.models.map(\.id)
check(Set(ids).count == ids.count, "catalog ids are unique")
for m in catalog.models {
    check(m.minRAM <= m.recRAM, "\(m.id) minRAM <= recRAM")
    check(m.minRAM > m.sizeGB, "\(m.id) minRAM leaves room beyond the weights")
}

let expected: [(MacSpecs, String)] = [
    (mac(8), "qwen3:4b"), (mac(16), "qwen3:8b"), (mac(24), "gpt-oss:20b"),
    (mac(32), "qwen3:30b"), (mac(48), "qwen3:32b"), (mac(64), "qwen3:32b"),
    (mac(128), "gpt-oss:120b"), (mac(16, arm: false), "llama3.2:3b"),
]
for (s, want) in expected {
    let got = recommend(catalog.models, for: s)?.id ?? "nil"
    print(String(format: "%4.0f GB %@ -> %@", s.memoryGB, s.appleSilicon ? "arm  " : "intel", got))
    check(got == want, "\(Int(s.memoryGB)) GB \(s.appleSilicon ? "arm" : "intel") recommends \(want), got \(got)")
}

// Low disk: never recommend a download that doesn't fit; installed models still count.
check(recommend(catalog.models, for: mac(32, disk: 6))?.sizeGB ?? 99 <= 4, "low disk picks a small model")
check(recommend(catalog.models, for: mac(32, disk: 1), installed: ["qwen3:30b"])?.id == "qwen3:30b", "installed model ignores disk")
check(recommend(catalog.models, for: mac(2)) == nil, "nothing fits 2 GB")
for gb in [4.0, 8, 16, 36, 64, 128] {
    check(recommend(catalog.models, for: mac(gb))?.recommendable == true, "uncensored and chat-only models are never recommended (\(gb) GB)")
}
func model(_ id: String) -> ModelInfo { catalog.models.first { $0.id == id }! }
check(fit(model("llama3.2:3b"), on: mac(8)) == .great, "llama3.2:3b great on 8 GB")
check(fit(model("qwen3:8b"), on: mac(64, arm: false)) == .slow, "8B is slow but usable on Intel")
check(fit(model("llama3.3:70b"), on: mac(64, arm: false)) == .tooSlow, "70B is too slow on Intel")
check(fit(model("qwen3:14b"), on: mac(16)) == .ok, "14B runs partly on CPU at 16 GB")

// Speed estimates
func speed(_ s: MacSpecs) -> (ModelInfo) -> SpeedEstimate {
    { Speed.estimate($0, on: s, machine: Speed.table(for: s)) }
}
let m4pro = mac(48, chip: "Apple M4 Pro")
check(Speed.table(for: m4pro).bandwidthGBs == 273 * Speed.bandwidthEfficiency, "M4 Pro bandwidth from table")
check(Speed.table(for: mac(32, chip: "Apple M3 Max")).bandwidthGBs == 400 * Speed.bandwidthEfficiency, "M3 Max beats M3 prefix")
check(speed(m4pro)(model("qwen3:8b")).tier == .fast, "qwen3:8b is fast on M4 Pro")
check(speed(m4pro)(model("qwen3:30b")).genTPS > speed(m4pro)(model("qwen3:14b")).genTPS, "MoE 30B outruns dense 14B")
let intel = mac(16, arm: false, chip: "Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz")
let i3b = speed(intel)(model("llama3.2:3b"))
print(String(format: "intel llama3.2:3b ≈ %.1f tok/s, first reply %.0f s (measured 5.5 tok/s, ~57 s)", i3b.genTPS, i3b.firstReplySeconds))
check(abs(i3b.genTPS - 5.5) < 1.5 && abs(i3b.firstReplySeconds - 57) < 20, "Intel table matches the measured i7-8700B")
check(speed(intel)(model("qwen3:14b")).tier == .veryslow, "14B is very slow on an Intel CPU")
// Speed-aware pick: an M1 with 64 GB fits dense 32B but it would crawl; take the MoE 30B.
let m1 = mac(64, chip: "Apple M1")
check(recommend(catalog.models, for: m1)?.id == "qwen3:32b", "fit-only pick on M1 64 GB is qwen3:32b")
check(recommend(catalog.models, for: m1, speed: speed(m1))?.id == "qwen3:30b", "speed-aware pick on M1 64 GB skips the very slow 32B")
check(recommend(catalog.models, for: intel, speed: speed(intel))?.id == "llama3.2:3b", "Intel keeps the readable 3B")
// Calibration reproduces the measured model exactly.
let b = Benchmark(model: "llama3.2:3b", genTPS: 5.5, promptTPS: 52, loadSeconds: 5, at: Date())
let cal = Speed.calibrate(from: b, model: model("llama3.2:3b"), sizeGB: 2.0, paramsB: 3.2, overheadS: Speed.intelOverhead)
check(abs(Speed.estimate(model("llama3.2:3b"), on: intel, machine: cal).genTPS - 5.5) < 0.01, "calibration round-trips")

print(failures == 0 ? "OK: all checks passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
