// Live control test against the Ollama on this Mac: restart, change port and back, stop, start.
// Interrupts Ollama for ~1 minute in total. Restores OLLAMA_HOST to its original value.
// swiftc -swift-version 5 mac/Sources/{Catalog,Ollama,Manager}.swift tests/control/main.swift -o build/control-test && build/control-test
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }
func ollama(on port: Int) -> Server? { Discovery.scan().first { $0.engine == .ollama && $0.ports.contains(port) } }

let originalHost = OllamaEnv.get("OLLAMA_HOST")
let origins = OllamaEnv.get("OLLAMA_ORIGINS")
let semaphore = DispatchSemaphore(value: 0)

Task {
    defer { semaphore.signal() }
    do {
        guard let s0 = ollama(on: 11434) else { print("No Ollama on 11434"); failures += 1; return }
        print("Found Ollama pid \(s0.pid) · \(s0.management.label)")

        print("1. Restart")
        try await Control.restart(s0)
        let s1 = ollama(on: 11434)
        check(s1 != nil && s1!.pid != s0.pid, "server back on 11434 with a new pid (\(s1?.pid ?? 0))")
        check(await Ollama.version(at: Ollama.url(port: 11434)) != nil, "API answers")

        print("2. Change port 11434 → 11435")
        try await Control.changePort(s1!, to: 11435)
        check(ollama(on: 11435) != nil, "server listens on 11435")
        check(ollama(on: 11434) == nil, "nothing on 11434")
        check(OllamaEnv.get("OLLAMA_HOST") == "127.0.0.1:11435", "OLLAMA_HOST=127.0.0.1:11435")
        let plist = (try? String(contentsOf: OllamaEnv.plist(OllamaEnv.agentLabel), encoding: .utf8)) ?? ""
        check(plist.contains("OLLAMA_HOST") && plist.contains("11435"), "LaunchAgent persists the port")
        check(await Ollama.allows(origin: SiteAccess.origins[0], at: Ollama.url(port: 11435)), "site still allowed on new port")

        print("3. Change port back → 11434")
        try await Control.changePort(ollama(on: 11435)!, to: 11434)
        check(ollama(on: 11434) != nil, "server back on 11434")
        check(OllamaEnv.get("OLLAMA_HOST").isEmpty, "OLLAMA_HOST unset again")

        print("4. Stop")
        try await Control.stop(ollama(on: 11434)!)
        check(await Ollama.waitForServer(at: Ollama.url(port: 11434), up: false, seconds: 15), "server stopped")

        print("5. Start")
        try await Ollama.launch(port: 11434)
        check(ollama(on: 11434) != nil, "server running again")
        check(await SiteAccess.allowed(), "site allowed")
    } catch {
        print("  FAIL error:", error.localizedDescription); failures += 1
    }
}
semaphore.wait()

// Safety net: restore the original environment whatever happened.
if OllamaEnv.get("OLLAMA_HOST") != originalHost { try? OllamaEnv.set("OLLAMA_HOST", originalHost.isEmpty ? nil : originalHost) }
check(OllamaEnv.get("OLLAMA_ORIGINS") == origins, "OLLAMA_ORIGINS unchanged")
print(failures == 0 ? "OK: control test passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
