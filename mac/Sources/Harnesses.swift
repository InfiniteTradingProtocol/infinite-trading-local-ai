import AppKit
import SwiftUI

// Coding agents on a local model. `ollama launch` does the wiring and offers
// to install what's missing; this app picks the model and opens it in Terminal.

struct Harness: Identifiable {
    let id: String
    let name: String
    let summary: String
    let binary: String
    /// Passed through `ollama launch` to the harness.
    var extraArgs: [String] = []

    static let all = [
        Harness(id: "claude", name: "Claude Code", summary: "Anthropic's coding agent. Asks before it edits files or runs commands.", binary: "claude"),
        Harness(id: "codex", name: "Codex", summary: "OpenAI's coding agent, limited to writing inside the workspace folder.", binary: "codex",
                extraArgs: ["--", "--sandbox", "workspace-write"]),
    ]

    static let workspace = URL(fileURLWithPath: NSHomeDirectory() + "/Infinite Agent Workspace")
    private static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    var isInstalled: Bool {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/local/bin", "/opt/homebrew/bin"]
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(binary)") }
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A login shell, so the harness and its installer find the user's PATH.
    func script(ollama: String, model: String, port: Int, folder: String) -> String {
        let args = [ollama, "launch", id, "--model", model] + extraArgs
        return """
        #!/bin/zsh -l
        cd \(Self.quoted(folder)) || exit 1
        export OLLAMA_HOST=\(Self.quoted("127.0.0.1:\(port)"))
        \(args.map(Self.quoted).joined(separator: " "))

        """
    }

    func open(ollama: String, model: String, port: Int) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.workspace, withIntermediateDirectories: true)
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Infinite Agent Manager/harnesses")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).command")
        try script(ollama: ollama, model: model, port: port, folder: Self.workspace.path).write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: Self.terminal, configuration: NSWorkspace.OpenConfiguration())
        Activity.log("Opened \(name) with \(model) in Terminal")
    }
}

struct HarnessesView: View {
    @EnvironmentObject var app: AppModel
    @State private var model = ""
    @State private var tools: Bool?
    @State private var problem: String?

    private var models: [String] {
        let chatOnly = Set(app.models.filter { $0.tags.contains("chat-only") }.flatMap(\.names))
        return app.installed.map(\.name).filter { !$0.contains("embed") && !chatOnly.contains($0) }.sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Run an agent on your own model").font(.system(size: 20, weight: .bold))
                Text("Coding agents open in Terminal and work inside \(Harness.workspace.lastPathComponent), in your home folder.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                picker
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber) }
                ForEach(Harness.all) { row($0) }
                agentRow
            }
            .padding(24)
        }
        .onAppear(perform: pickDefault)
        .onChange(of: models) { _ in pickDefault() }
        .task(id: model) {
            tools = nil
            if !model.isEmpty { tools = await Ollama.supportsTools(model) }
        }
    }

    private var picker: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if models.isEmpty {
                    Text("Download a model in the Library first. Chat only models are too small for these agents.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 420)
                }
                if tools == false {
                    note("\(model) doesn't support tool calling, so these agents can't edit files or run commands with it.")
                }
                if app.specs.memoryGB < 24 {
                    note("Ollama gives models 4K of context by default on Macs under 24 GB. Coding agents need about 32K, so long sessions may lose their instructions.")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ h: Harness) -> some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(h.name).font(.system(size: 14, weight: .semibold))
                        Chip(text: h.isInstalled ? "Installed" : "Not installed", color: h.isInstalled ? Theme.green : Theme.dim)
                    }
                    Text(h.summary).font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(h.isInstalled ? "Open in Terminal" : "Install in Terminal") { open(h) }
                    .buttonStyle(PrimaryButton(compact: true))
                    .fixedSize()
                    .disabled(model.isEmpty)
            }
        }
    }

    private var agentRow: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Infinite Agent").font(.system(size: 14, weight: .semibold))
                    Text("Our trading agent, in your browser on infinitetrading.io, using the models on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Open") {
                    Task {
                        guard await app.installOllama() else { return }
                        if !app.siteAllowed { guard await app.connectSite() else { return } }
                        app.openAgent()
                    }
                }
                .buttonStyle(PrimaryButton(compact: true))
                .fixedSize()
            }
        }
    }

    private func pickDefault() {
        let uncensored = Set(app.models.filter(\.uncensored).flatMap(\.names))
        if !models.contains(model) { model = models.first { !uncensored.contains($0) } ?? models.first ?? "" }
    }

    private func open(_ h: Harness) {
        problem = nil
        Task {
            guard await app.installOllama() else { return }
            guard let binary = Ollama.serverBinary() else { problem = "Ollama isn't installed."; return }
            do { try await h.open(ollama: binary, model: model, port: Ollama.port) }
            catch { problem = error.localizedDescription }
        }
    }
}
