// Update consent, against the real release feed: with automatic updates off, a
// check reports the new version but downloads, stages and installs nothing.
// A command-line binary has no bundle version, so every release counts as newer.
// swiftc -swift-version 5 $(ls mac/Sources/*.swift | grep -v App.swift) tests/updates/main.swift -o build/updates-test && build/updates-test
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }

Task { @MainActor in
    UserDefaults.standard.removeObject(forKey: "autoInstallUpdates")
    let m = UpdateModel()
    check(m.autoInstall == false, "automatic updates are off by default")
    for initiated in [false, true] {
        await m.check(userInitiated: initiated)
        guard let u = m.available else { check(false, "finds a release: \(m.status)"); continue }
        check(m.staged == nil && m.progress == nil, "\(initiated ? "manual" : "scheduled") check stages nothing")
        check(!FileManager.default.fileExists(atPath: Updater.workDir.appendingPathComponent(u.version).path),
              "\(initiated ? "manual" : "scheduled") check downloads nothing")
        check(m.status == "Version \(u.version) is available", "says so: \(m.status)")
    }
    print(failures == 0 ? "PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
