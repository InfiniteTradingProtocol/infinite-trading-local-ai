import AppKit
import WebKit

// The Infinite Agent in its own window. The page comes from the website; this
// file adds one thing it can't do from there: an https page may not call the
// Ollama on this Mac, so its model requests are carried over by the app.

enum AgentBridge {
    static let home = URL(string: "https://www.infinitetrading.io/agent-app")!
    private static let hosts: Set<String> = ["www.infinitetrading.io", "infinitetrading.io"]
    /// The only Ollama calls the page can make: reading models and chatting.
    private static let routes = ["api/tags": "GET", "api/version": "GET", "api/show": "POST", "api/chat": "POST"]

    static func isSite(scheme: String?, host: String?) -> Bool {
        scheme == "https" && hosts.contains(host ?? "")
    }

    static func allowed(path: String, method: String) -> Bool { routes[path] == method }

    /// Runs before the page's own scripts. Replaces fetch for Ollama addresses only.
    static func script(defaultModel: String?) -> String {
        let settings = (try? JSONSerialization.data(withJSONObject: ["defaultModel": defaultModel ?? ""]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          if (!["https://www.infinitetrading.io", "https://infinitetrading.io"].includes(location.origin)) return;
          const local = /^http:\\/\\/(?:localhost|127\\.0\\.0\\.1)(?::\\d+)?\\/(api\\/[a-z]+)$/;
          const post = (m) => window.webkit.messageHandlers.ilaBridge.postMessage(m);
          const open = new Map();
          let next = 0;
          const page = window.fetch.bind(window);
          window.__ila = Object.assign(\(settings), {
            head(id, status) {
              const c = open.get(id);
              if (c) c.resolve(new Response(c.body, { status, headers: { "Content-Type": "application/x-ndjson" } }));
            },
            push(id, text) { open.get(id)?.stream.enqueue(new TextEncoder().encode(text)); },
            end(id, error) {
              const c = open.get(id);
              if (!c) return;
              open.delete(id);
              if (error) { c.reject(new TypeError(error)); try { c.stream.error(new TypeError(error)); } catch {} }
              else { try { c.stream.close(); } catch {} }
            },
          });
          window.fetch = (input, init = {}) => {
            const url = typeof input === "string" ? input : input.url ?? String(input);
            const m = local.exec(url);
            if (!m) return page(input, init);
            const id = ++next;
            return new Promise((resolve, reject) => {
              const cancel = () => post({ id, cancel: true });
              let stream;
              const body = new ReadableStream({ start(c) { stream = c; }, cancel });
              open.set(id, { resolve, reject, body, stream });
              init.signal?.addEventListener("abort", () => {
                cancel();
                window.__ila.end(id, "Aborted");
              });
              post({ id, path: m[1], method: init.method ?? "GET", body: typeof init.body === "string" ? init.body : "" });
            });
          };
        })();
        """
    }
}

@MainActor
final class AgentWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let shared = AgentWindow()

    private(set) var web: WKWebView?
    private var window: NSWindow?
    private var requests: [Int: Task<Void, Never>] = [:]

    func show(defaultModel: String?) {
        prepare(defaultModel: defaultModel)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func prepare(defaultModel: String?) {
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: AgentBridge.script(defaultModel: defaultModel), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(self, name: "ilaBridge")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 800), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Infinite Agent"
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.minSize = NSSize(width: 760, height: 560)
        w.center()
        w.setFrameAutosaveName("InfiniteAgentWindow")
        web = view
        window = w
        view.load(URLRequest(url: AgentBridge.home))
    }

    // MARK: Model requests from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, AgentBridge.isSite(scheme: origin.`protocol`, host: origin.host),
              let m = message.body as? [String: Any], let id = m["id"] as? Int else { return }
        if m["cancel"] != nil {
            requests.removeValue(forKey: id)?.cancel()
            return
        }
        let path = m["path"] as? String ?? ""
        let method = m["method"] as? String ?? ""
        guard AgentBridge.allowed(path: path, method: method) else {
            reply("end", id, "This request isn't allowed.")
            return
        }
        var request = URLRequest(url: Ollama.base.appendingPathComponent(path), timeoutInterval: 900)
        request.httpMethod = method
        if let body = m["body"] as? String, !body.isEmpty {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        requests[id] = Task { [weak self] in
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                await self?.call("head", id, (response as? HTTPURLResponse)?.statusCode ?? 500)
                for try await line in bytes.lines { await self?.call("push", id, line + "\n") }
                self?.reply("end", id, nil)
            } catch {
                if !Task.isCancelled { self?.reply("end", id, "Couldn't reach Ollama.") }
            }
            self?.requests[id] = nil
        }
    }

    private func reply(_ fn: String, _ id: Int, _ value: Any?) { Task { await call(fn, id, value) } }

    /// Values travel as arguments, never spliced into the script text.
    private func call(_ fn: String, _ id: Int, _ value: Any?) async {
        guard let web else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            web.callAsyncJavaScript("window.__ila?.\(fn)(id, value)", arguments: ["id": id, "value": value ?? NSNull()],
                                    in: nil, in: .page) { _ in done.resume() }
        }
    }

    // MARK: Staying on the site

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        guard action.targetFrame?.isMainFrame == true, !AgentBridge.isSite(scheme: url?.scheme, host: url?.host) else {
            decisionHandler(.allow)
            return
        }
        if let url { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    /// New windows (wallet sites, docs) open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}
