// The Agent window's bridge, live: loads the real site hidden and sends model
// calls through it. Needs Ollama running (default model llama3.2:1b).
// xcrun swiftc -swift-version 5 $(ls mac/Sources/*.swift | grep -v App.swift) tests/agent-bridge/main.swift -o build/agent-bridge-test && build/agent-bridge-test
import AppKit
import WebKit

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }

check(AgentBridge.isSite(scheme: "https", host: "www.infinitetrading.io"), "our site is allowed")
check(!AgentBridge.isSite(scheme: "http", host: "www.infinitetrading.io"), "not over http")
check(!AgentBridge.isSite(scheme: "https", host: "www.infinitetrading.io.evil.com"), "not a lookalike host")
check(AgentBridge.allowed(path: "api/chat", method: "POST"), "chat is allowed")
for (p, m) in [("api/delete", "DELETE"), ("api/pull", "POST"), ("api/create", "POST"), ("api/chat", "DELETE")] {
    check(!AgentBridge.allowed(path: p, method: m), "\(m) \(p) is refused")
}

let service = "Infinite Agent Manager Test \(UUID().uuidString)"
let first = try! AppKeychain.masterKey(service: service)
check(first.count == 32, "creates a 32-byte key")
check(try! AppKeychain.masterKey(service: service) == first, "the same key comes back")
AppKeychain.delete(service: service)

let model = ProcessInfo.processInfo.environment["ILA_TEST_MODEL"] ?? "llama3.2:1b"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

@MainActor func js(_ body: String) async -> String {
    await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
        AgentWindow.shared.web!.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { r in
            switch r {
            case .success(let v): done.resume(returning: "\(v)")
            case .failure(let e): done.resume(returning: "ERROR \(e.localizedDescription)")
            }
        }
    }
}
func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

Task { @MainActor in
    AgentWindow.shared.prepare(defaultModel: model)
    await wait(15)
    check(await js("return window.__ila?.defaultModel") == model, "the page received the default model")

    let tags = await js("const r = await fetch('http://localhost:11434/api/tags'); const j = await r.json(); return r.status + ' ' + j.models.length")
    check(tags.hasPrefix("200 "), "lists models from an https page (\(tags))")
    check(await js("return (await fetch('http://localhost:11434/api/pull', {method:'POST', body:'{}'}).catch(e => ({status:'refused'}))).status") == "refused", "the page can't download models")

    let chat = """
    const r = await fetch('http://127.0.0.1:11434/api/chat', {method:'POST', body: JSON.stringify({model:'\(model)', stream:true, messages:[{role:'user',content:'Say hi'}], options:{num_predict:12}})});
    const rd = r.body.getReader(); const d = new TextDecoder(); let n = 0, t = '';
    for (;;) { const {value, done} = await rd.read(); if (done) break; t += d.decode(value); n++; }
    const frames = t.trim().split('\\n').map(JSON.parse);
    return n + ' ' + frames.length + ' ' + frames.at(-1).done;
    """
    let streamed = await js(chat)
    let parts = streamed.split(separator: " ")
    check(parts.count == 3 && Int(parts[0])! > 1 && parts[2] == "true", "chat streams in pieces and finishes (\(streamed))")

    let abort = """
    const c = new AbortController();
    const p = fetch('http://127.0.0.1:11434/api/chat', {method:'POST', signal:c.signal, body: JSON.stringify({model:'\(model)', stream:true, messages:[{role:'user',content:'Count to 500'}]})});
    setTimeout(() => c.abort(), 50);
    try { const r = await p; const rd = r.body.getReader(); for (;;) { const {done} = await rd.read(); if (done) return 'finished'; } } catch (e) { return 'stopped'; }
    """
    check(await js(abort) == "stopped", "Stop cancels the request")

    let key = await js("return atob(await window.__ila.masterKey()).length")
    check(key == "32", "the page gets a 32-byte key from the Keychain (\(key))")
    AppKeychain.delete(service: AppKeychain.name)

    await wait(4)
    let page = await js("return document.body.innerText.slice(0, 2000)")
    check(page.contains("Infinite Agent") && page.contains("Connect Wallet"), "the page shows the agent and the wallet button")
    check(!page.contains("Connect a model"), "the local model connected by itself")
    if let path = ProcessInfo.processInfo.environment["ILA_SHOT"],
       let img = try? await AgentWindow.shared.web!.takeSnapshot(configuration: nil),
       let t = img.tiffRepresentation, let p = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
        try? p.write(to: URL(fileURLWithPath: path))
    }
    print(failures == 0 ? "All passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
