import AppKit
import SwiftUI

// Chat: try any local model on this Mac before using it with the Infinite Agent.
// Talks straight to the server on 127.0.0.1 (Ollama's /api/chat, or the
// OpenAI-compatible /v1/chat/completions of LM Studio, llama.cpp, MLX LM…),
// streams the answer and measures the speed. Nothing is saved or sent anywhere else.

struct ChatTarget: Hashable, Identifiable {
    enum API: Hashable { case ollama, openAI }
    let api: API
    let base: URL
    let model: String
    /// "Ollama · 11434"
    let server: String
    var id: String { base.absoluteString + "|" + model }
}

struct ChatStats {
    var tokens: Int
    var tokensPerSecond: Double?
    var firstWordSeconds: Double
    var promptTokens: Int?
    var promptPerSecond: Double?
    var loadSeconds: Double?
    /// Counted by the server; otherwise estimated from stream chunks.
    var exact: Bool

    var summary: String {
        var parts = ["\(exact ? "" : "≈")\(tokens) tokens"]
        if let t = tokensPerSecond { parts.append(String(format: "%.1f tok/s", t)) }
        parts.append(String(format: "first word %.1f s", firstWordSeconds))
        if let p = promptTokens, let r = promptPerSecond { parts.append(String(format: "prompt %d tok at %.0f tok/s", p, r)) }
        if let l = loadSeconds, l >= 0.5 { parts.append(String(format: "model load %.1f s", l)) }
        return parts.joined(separator: " · ")
    }
}

struct ChatMessage: Identifiable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var thinking = ""
    var model: String?
    var started = Date()
    var stats: ChatStats?
    var error: String?

    /// Thinking (from the API or inline `<think>` tags) and the answer, separated.
    var parts: (thinking: String, answer: String) {
        var thinking = self.thinking, answer = text
        if let open = answer.range(of: "<think>") {
            let after = answer[open.upperBound...]
            if let close = after.range(of: "</think>") {
                thinking += after[..<close.lowerBound]
                answer = String(answer[..<open.lowerBound]) + String(after[close.upperBound...])
            } else {
                thinking += after
                answer = String(answer[..<open.lowerBound])
            }
        }
        return (thinking.trimmingCharacters(in: .whitespacesAndNewlines), answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    @Published var messages: [ChatMessage] = []
    @Published var target: ChatTarget?
    @Published var input = ""
    @Published var system = ""
    @Published var streaming = false
    private var task: Task<Void, Never>?

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target, !streaming else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        var history: [[String: String]] = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : [["role": "system", "content": system]]
        for m in messages where m.error == nil {
            let content = m.role == .user ? m.text : m.parts.answer
            if !content.isEmpty { history.append(["role": m.role.rawValue, "content": content]) }
        }
        messages.append(ChatMessage(role: .assistant, text: "", model: target.model))
        let i = messages.count - 1
        streaming = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let stats = try await self.stream(target, history: history) { [weak self] text, thinking in
                    self?.messages[i].text += text
                    self?.messages[i].thinking += thinking
                }
                self.messages[i].stats = stats
                if let t = stats.tokensPerSecond {
                    Activity.log(String(format: "Chat: %@ on %@ answered %d tokens at %.1f tok/s", target.model, target.server, stats.tokens, t))
                }
            } catch {
                self.messages[i].error = Task.isCancelled || (error as? URLError)?.code == .cancelled
                    ? "Stopped." : error.localizedDescription
            }
            self.streaming = false
        }
    }

    func stop() { task?.cancel() }

    func clear() {
        stop()
        messages = []
    }

    /// Opens a model on this Mac's main Ollama server in the chat.
    func select(ollamaModel name: String) {
        target = ChatTarget(api: .ollama, base: Ollama.base, model: name, server: "Ollama · \(Ollama.port)")
    }

    // MARK: Streaming

    private func stream(_ t: ChatTarget, history: [[String: String]],
                        onDelta: (String, String) -> Void) async throws -> ChatStats {
        switch t.api {
        case .ollama: return try await streamOllama(t, history, onDelta)
        case .openAI:
            do { return try await streamOpenAI(t, history, usage: true, onDelta) }
            catch let e as HTTPStatus where e.code == 400 {
                return try await streamOpenAI(t, history, usage: false, onDelta) // server rejects stream_options
            }
        }
    }

    private struct HTTPStatus: LocalizedError {
        let code: Int, message: String
        var errorDescription: String? { message }
    }

    private func post(_ url: URL, _ body: [String: Any]) async throws -> URLSession.AsyncBytes {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        // Idle time between bytes: a slow model can think for minutes before its first word.
        r.timeoutInterval = 900
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 400 { break } }
            let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let msg = (obj?["error"] as? String) ?? ((obj?["error"] as? [String: Any])?["message"] as? String)
            throw HTTPStatus(code: code, message: "The server answered HTTP \(code)" + (msg.map { ": \($0)" } ?? "."))
        }
        return bytes
    }

    private func streamOllama(_ t: ChatTarget, _ history: [[String: String]],
                              _ onDelta: (String, String) -> Void) async throws -> ChatStats {
        let start = Date()
        var firstWord: Double?
        let bytes = try await post(t.base.appendingPathComponent("api/chat"),
                                   ["model": t.model, "messages": history, "stream": true, "options": ["num_ctx": 16384]])
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { throw Ollama.Failure("Ollama: \(e)") }
            let msg = obj["message"] as? [String: Any]
            let text = msg?["content"] as? String ?? "", thinking = msg?["thinking"] as? String ?? ""
            if firstWord == nil && !(text + thinking).isEmpty { firstWord = Date().timeIntervalSince(start) }
            onDelta(text, thinking)
            if obj["done"] as? Bool == true {
                let n = { (k: String) in (obj[k] as? NSNumber)?.doubleValue }
                let evalCount = n("eval_count") ?? 0, evalNs = n("eval_duration") ?? 0
                let promptCount = n("prompt_eval_count"), promptNs = n("prompt_eval_duration")
                return ChatStats(
                    tokens: Int(evalCount),
                    tokensPerSecond: evalNs > 0 ? evalCount / (evalNs / 1e9) : nil,
                    firstWordSeconds: firstWord ?? Date().timeIntervalSince(start),
                    promptTokens: promptCount.map(Int.init),
                    promptPerSecond: promptCount.flatMap { c in promptNs.flatMap { $0 > 0 ? c / ($0 / 1e9) : nil } },
                    loadSeconds: n("load_duration").map { $0 / 1e9 },
                    exact: true)
            }
        }
        throw Ollama.Failure("The answer stopped before it finished.")
    }

    private func streamOpenAI(_ t: ChatTarget, _ history: [[String: String]], usage: Bool,
                              _ onDelta: (String, String) -> Void) async throws -> ChatStats {
        let start = Date()
        var firstWord: Double?
        var chunks = 0
        var completion: Int?, prompt: Int?
        var body: [String: Any] = ["model": t.model, "messages": history, "stream": true]
        if usage { body["stream_options"] = ["include_usage": true] }
        let bytes = try await post(t.base.appendingPathComponent("v1/chat/completions"), body)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let e = obj["error"] as? [String: Any] { throw Ollama.Failure(e["message"] as? String ?? "The server reported an error.") }
            if let u = obj["usage"] as? [String: Any] {
                completion = (u["completion_tokens"] as? NSNumber)?.intValue
                prompt = (u["prompt_tokens"] as? NSNumber)?.intValue
            }
            let delta = ((obj["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any]
            let text = delta?["content"] as? String ?? ""
            let thinking = (delta?["reasoning_content"] as? String) ?? (delta?["reasoning"] as? String) ?? ""
            if (text + thinking).isEmpty { continue }
            if firstWord == nil { firstWord = Date().timeIntervalSince(start) }
            chunks += 1
            onDelta(text, thinking)
        }
        let first = firstWord ?? Date().timeIntervalSince(start)
        let writing = Date().timeIntervalSince(start) - first
        let tokens = completion ?? chunks
        return ChatStats(tokens: tokens, tokensPerSecond: writing > 0.2 ? Double(tokens) / writing : nil,
                         firstWordSeconds: first, promptTokens: prompt, promptPerSecond: nil,
                         loadSeconds: nil, exact: completion != nil)
    }
}

// MARK: View

struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var manager: ManagerModel
    @EnvironmentObject var nav: Nav
    @ObservedObject private var chat = ChatModel.shared
    @State private var showSystem = false

    /// Every chat-capable model on every local server.
    var targets: [ChatTarget] {
        manager.servers.flatMap { s -> [ChatTarget] in
            guard let base = s.base, let port = s.apiPort else { return [] }
            let server = "\(s.engine.rawValue) · \(port)"
            let names = s.engine == .ollama ? s.installed.sorted() : s.apiModels
            return names.filter { !$0.lowercased().contains("embed") }
                .map { ChatTarget(api: s.engine == .ollama ? .ollama : .openAI, base: base, model: $0, server: server) }
        }
    }

    var body: some View {
        let targets = self.targets
        VStack(spacing: 0) {
            if targets.isEmpty && chat.messages.isEmpty {
                empty
            } else {
                header(targets)
                transcript
                composer
            }
        }
        .onAppear { pickDefault(targets) }
        .onChange(of: targets.map(\.id)) { _ in pickDefault(self.targets) }
    }

    private func pickDefault(_ targets: [ChatTarget]) {
        if let t = chat.target, targets.contains(t) || chat.streaming { return }
        let preferred = app.recommended.flatMap { m in targets.first { $0.api == .ollama && m.names.contains($0.model) } }
        chat.target = preferred ?? targets.first
    }

    /// The three best-rated catalog models installed in Ollama (never uncensored or chat only).
    private func recommendedTargets(_ targets: [ChatTarget]) -> [ChatTarget] {
        let rated = targets.compactMap { t -> (ChatTarget, Int)? in
            guard t.api == .ollama, let m = app.models.first(where: { $0.names.contains(t.model) }), m.recommendable else { return nil }
            return (t, m.rank)
        }
        return Array(rated.sorted { $0.1 > $1.1 }.prefix(3).map(\.0))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundStyle(Theme.violet)
            Text("No chat models are running").font(.system(size: 17, weight: .bold))
            Text("Install a model in the Library, or start Ollama, LM Studio or another local server. It shows up here to try.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { nav.tab = .library } label: { Label("Open the Library", systemImage: "square.grid.2x2") }
                .buttonStyle(PrimaryButton(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ targets: [ChatTarget]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    let top = recommendedTargets(targets)
                    let rest = targets.filter { !top.contains($0) }
                    if !top.isEmpty {
                        Section("Recommended models") {
                            ForEach(top) { t in Button(t.model) { chat.target = t } }
                        }
                    }
                    let servers = Array(NSOrderedSet(array: rest.map(\.server))) as? [String] ?? []
                    ForEach(servers, id: \.self) { server in
                        Section(top.isEmpty ? server : "Other models · \(server)") {
                            ForEach(rest.filter { $0.server == server }) { t in
                                Button(t.model) { chat.target = t }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                        Text(chat.target?.model ?? "Choose a model").font(.system(size: 13, weight: .semibold))
                        if let s = chat.target?.server { Text(s).font(.system(size: 11)).foregroundStyle(Theme.dim) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(chat.streaming)
                if let est = estimate { Chip(text: est.label, color: color(est.tier)) }
                Spacer()
                Button { showSystem.toggle() } label: { Label("System prompt", systemImage: showSystem ? "chevron.up" : "text.quote") }
                    .buttonStyle(GhostButton())
                Button { chat.clear() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .buttonStyle(GhostButton()).disabled(chat.messages.isEmpty)
            }
            if let w = estimate?.warning {
                Text(w).font(.system(size: 11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            if showSystem {
                TextField("Optional instructions sent before the conversation, e.g. “Answer in one paragraph.”",
                          text: $chat.system, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    /// The Library's speed estimate, for Ollama models.
    private var estimate: SpeedEstimate? {
        guard let t = chat.target, t.api == .ollama else { return nil }
        if let m = app.models.first(where: { $0.names.contains(t.model) }) { return app.estimate(m) }
        return app.installed.first { $0.name == t.model }.map { app.estimate(app.info(for: $0)) }
    }

    private func color(_ tier: SpeedEstimate.Tier) -> Color {
        switch tier {
        case .veryslow: return Theme.red
        case .slow: return Theme.amber
        case .ok: return Theme.cyan
        case .fast: return Theme.green
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty {
                        Text("Ask anything to see how this model answers and how fast it runs on this Mac. Chats stay in this window and aren't saved.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.dim).padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(chat.messages) { m in
                        ChatBubble(message: m, live: chat.streaming && m.id == chat.messages.last?.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
            .onChange(of: chat.messages.last?.text) { _ in proxy.scrollTo("bottom") }
            .onChange(of: chat.messages.last?.thinking) { _ in proxy.scrollTo("bottom") }
            .onChange(of: chat.messages.count) { _ in withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(chat.target.map { "Message \($0.model)…" } ?? "Choose a model first", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...8)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                    .onSubmit { chat.send() }
                    .disabled(chat.target == nil)
                if chat.streaming {
                    Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(GhostButton(tint: Theme.red))
                } else {
                    Button { chat.send() } label: { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(PrimaryButton(compact: true)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(chat.target == nil || chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Return sends · Option-Return adds a line. Runs on 127.0.0.1; nothing is sent to Infinite Trading.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let live: Bool

    var body: some View {
        let user = message.role == .user
        let (thinking, answer) = user ? ("", message.text) : message.parts
        HStack(alignment: .top) {
            if user { Spacer(minLength: 120) }
            VStack(alignment: .leading, spacing: 7) {
                if let model = message.model {
                    Text(model).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.violet)
                }
                if !thinking.isEmpty {
                    DisclosureGroup(live && answer.isEmpty ? "Thinking…" : "Thought") {
                        Text(thinking).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                if !answer.isEmpty {
                    Text(markdown(answer)).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if live && thinking.isEmpty {
                    TimelineView(.periodic(from: message.started, by: 1)) { ctx in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Reading the prompt… \(Int(ctx.date.timeIntervalSince(message.started))) s")
                                .font(.system(size: 12)).foregroundStyle(Theme.dim)
                        }
                    }
                }
                if let e = message.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(e == "Stopped." ? Theme.dim : Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = message.stats {
                    Text(s.summary).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(user ? Theme.violet.opacity(0.22) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(user ? Theme.violet.opacity(0.4) : Theme.stroke))
            if !user { Spacer(minLength: 120) }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
