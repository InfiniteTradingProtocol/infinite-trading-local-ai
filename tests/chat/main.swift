// Live chat test against the Ollama on this Mac (needs a small model, default llama3.2:1b).
// Exercises both APIs the Chat tab speaks: Ollama's /api/chat and the OpenAI-compatible
// /v1/chat/completions (which Ollama also serves), multi-turn context, and Stop.
// swiftc -swift-version 5 $(ls mac/Sources/*.swift | grep -v App.swift) tests/chat/main.swift -o build/chat-test && build/chat-test [model]
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { failures += 1 } }
let model = CommandLine.arguments.dropFirst().first ?? "llama3.2:1b"

@MainActor func ask(_ chat: ChatModel, _ text: String, stopAfterFirstWord: Bool = false) async -> ChatMessage {
    chat.input = text
    chat.send()
    while chat.streaming {
        if stopAfterFirstWord && !(chat.messages.last?.text ?? "").isEmpty { chat.stop() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return chat.messages.last!
}

Task { @MainActor in
    let chat = ChatModel.shared
    for api in [ChatTarget.API.ollama, .openAI] {
        print(api == .ollama ? "Ollama /api/chat" : "OpenAI-compatible /v1/chat/completions")
        chat.clear()
        chat.target = ChatTarget(api: api, base: Ollama.base, model: model, server: "Ollama · \(Ollama.port)")
        let a = await ask(chat, "My name is Ada. Reply with one short sentence.")
        check(a.error == nil, "answers without error \(a.error ?? "")")
        check(!a.parts.answer.isEmpty, "streams an answer (\(a.parts.answer.prefix(50))…)")
        check((a.stats?.tokens ?? 0) > 0 && (a.stats?.tokensPerSecond ?? 0) > 0, "measures speed: \(a.stats?.summary ?? "none")")
        if api == .ollama { check(a.stats?.exact == true && a.stats?.promptTokens != nil, "Ollama reports exact counts") }
        let b = await ask(chat, "What is my name? Answer with just the name.")
        check(b.parts.answer.lowercased().contains("ada"), "keeps the conversation (\(b.parts.answer.prefix(40)))")
    }
    chat.clear()
    chat.target = ChatTarget(api: .ollama, base: Ollama.base, model: model, server: "Ollama")
    let c = await ask(chat, "Count from 1 to 200, one number per line.", stopAfterFirstWord: true)
    check(c.error == "Stopped." && !chat.streaming, "Stop ends the answer (\(c.error ?? "no error"))")
    chat.target = ChatTarget(api: .ollama, base: Ollama.base, model: "no-such-model:0b", server: "Ollama")
    chat.clear()
    let d = await ask(chat, "hi")
    check(d.error != nil && d.error != "Stopped.", "missing model shows an error (\(d.error ?? "none"))")
    print(failures == 0 ? "PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
