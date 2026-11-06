// swiftc -swift-version 5 mac/Sources/Catalog.swift tests/recommend/main.swift -o build/recommend-test && build/recommend-test
import Foundation

let catalog = try! Catalog.load(from: URL(fileURLWithPath: "catalog/models.json"))
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

func mac(_ ram: Double, arm: Bool = true, disk: Double = 500) -> MacSpecs {
    MacSpecs(chip: "test", appleSilicon: arm, memoryGB: ram, freeDiskGB: disk, osMajor: 15, osVersion: "15.0")
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
func model(_ id: String) -> ModelInfo { catalog.models.first { $0.id == id }! }
check(fit(model("llama3.2:3b"), on: mac(8)) == .great, "llama3.2:3b great on 8 GB")
check(fit(model("qwen3:8b"), on: mac(64, arm: false)) == .slow, "8B is slow but usable on Intel")
check(fit(model("llama3.3:70b"), on: mac(64, arm: false)) == .tooSlow, "70B is too slow on Intel")
check(fit(model("qwen3:14b"), on: mac(16)) == .ok, "14B runs partly on CPU at 16 GB")

print(failures == 0 ? "OK: all checks passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
