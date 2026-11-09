// The launch script and who counts as the Ollama desktop app. Opens nothing.
// xcrun swiftc -swift-version 5 $(ls mac/Sources/*.swift | grep -v App.swift) tests/harnesses/main.swift -o build/harnesses-test && build/harnesses-test
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }

let serve = "/Applications/Ollama.app/Contents/Resources/ollama serve"
let gui = "/Applications/Ollama.app/Contents/MacOS/Ollama"
check(Management.ownedByOllamaApp(serve, parent: gui), "server under the desktop app belongs to it")
check(!Management.ownedByOllamaApp(serve, parent: "/Applications/Infinite Agent Manager.app/Contents/MacOS/x"), "server this app started is not the desktop app's")
check(!Management.ownedByOllamaApp(serve, parent: "/sbin/launchd"), "orphaned server is not the desktop app's")

check(Ollama.serverBinary(in: URL(fileURLWithPath: "/nonexistent/Ollama.app")) == Ollama.cliPath, "falls back to the CLI when the app has no binary")

let codex = Harness.all.first { $0.id == "codex" }!
let evil = "x'; touch /tmp/ila-pwned; '"
let script = codex.script(ollama: "/a b/ollama", model: evil, port: 11434, folder: "/Users/me/It's here")
check(script.hasPrefix("#!/bin/zsh -l\n"), "starts with a login-shell shebang")
check(script.contains("'--' '--sandbox' 'workspace-write'"), "Codex keeps its sandbox")
check(Harness.all.allSatisfy { !$0.extraArgs.contains("-y") && !$0.extraArgs.contains("--yes") }, "nothing auto-approves")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ila-harness-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fake = dir.appendingPathComponent("ollama")
try! "#!/bin/sh\nfor a in \"$@\"; do echo \"[$a]\"; done\n".write(to: fake, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
let live = codex.script(ollama: fake.path, model: evil, port: 11500, folder: dir.path)
let file = dir.appendingPathComponent("run.command")
try! live.write(to: file, atomically: true, encoding: .utf8)
let r = shell("/bin/zsh", [file.path])
check(r.status == 0, "script runs")
check(r.out.contains("[\(evil)]"), "a hostile model name arrives as one argument")
check(!FileManager.default.fileExists(atPath: "/tmp/ila-pwned"), "and doesn't execute")
try? FileManager.default.removeItem(at: dir)

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
