import AppKit
import SwiftUI

// MARK: Theme

enum Theme {
    static let bgTop = Color(red: 0.06, green: 0.04, blue: 0.14)
    static let bgBottom = Color(red: 0.03, green: 0.02, blue: 0.08)
    static let card = Color.white.opacity(0.05)
    static let stroke = Color.white.opacity(0.09)
    static let violet = Color(red: 0.62, green: 0.45, blue: 1.0)
    static let magenta = Color(red: 0.86, green: 0.42, blue: 1.0)
    static let cyan = Color(red: 0.45, green: 0.78, blue: 1.0)
    static let green = Color(red: 0.36, green: 0.86, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.36)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.5)
    static let dim = Color.white.opacity(0.55)
    static let accent = LinearGradient(colors: [violet, magenta], startPoint: .leading, endPoint: .trailing)

    static func fitColor(_ f: Fit) -> Color {
        switch f {
        case .great: return green
        case .ok: return cyan
        case .slow: return amber
        case .tooSlow, .tooLarge, .noDisk: return red
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct PrimaryButton: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 10)
            .background(Capsule().fill(Theme.accent).opacity(enabled ? 1 : 0.4))
            .shadow(color: Theme.violet.opacity(enabled ? 0.45 : 0), radius: 12, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View { GhostBody(configuration: configuration, tint: tint) }
}

private struct GhostBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .opacity(enabled ? 1 : 0.35)
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.dim
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct Bar: View {
    let fraction: Double?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, g.size.width * (fraction ?? 0.08)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

func tagChip(_ tag: String) -> Chip {
    switch tag {
    case "tools": return Chip(text: "Tool use", color: Theme.cyan)
    case "reasoning": return Chip(text: "Reasoning", color: Theme.magenta)
    case "vision": return Chip(text: "Vision", color: Theme.amber)
    case "fast": return Chip(text: "Fast", color: Theme.green)
    default: return Chip(text: tag)
    }
}

// MARK: Root

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 300)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            MainPane()
        }
        .background(
            ZStack {
                LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.violet.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Theme.magenta.opacity(0.10), .clear], center: .bottomLeading, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        )
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { app.start() }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 46, height: 46)
                    .shadow(color: Theme.violet.opacity(0.6), radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Infinite Agent Manager").font(.system(size: 16, weight: .bold))
                    Text("Local models for the Infinite Agent").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.top, 8)

            SpecsCard()
            StepsCard()
            Spacer(minLength: 0)

            Button { app.openAgent() } label: {
                Label("Open Infinite Agent", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
            .disabled(!app.ready)
            Text(app.ready
                 ? "On the site choose Ollama → Connect. Accept the browser's local-network prompt if asked."
                 : "Finish the three steps above to connect.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

struct SpecsCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let s = app.specs
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR MAC").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Theme.dim)
                spec("cpu", "Chip", s.shortChip)
                spec("memorychip", "Memory", "\(Int(s.memoryGB)) GB" + (s.appleSilicon ? " unified" : ""))
                spec("bolt.horizontal", "For models", "≈ \(Int(s.gpuBudgetGB)) GB" + (s.appleSilicon ? " on GPU" : " on CPU"))
                spec("internaldrive", "Free disk", formatGB(s.freeDiskGB))
                spec("apple.logo", "macOS", s.osVersion)
                if app.osTooOld {
                    Text("Ollama needs macOS \(Ollama.minMacOS) or newer.")
                        .font(.system(size: 11)).foregroundStyle(Theme.red)
                } else if !s.appleSilicon {
                    Text("Intel Mac: models run on the CPU, so small ones work best.")
                        .font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    func spec(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.violet)
            Text(k).foregroundStyle(Theme.dim)
            Spacer()
            Text(v).fontWeight(.medium).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct StepsCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("SETUP").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Theme.dim)
                step(1, "Ollama", ollamaDetail, done: app.running, busy: app.ollamaJob != nil) {
                    if !app.running && app.ollamaJob == nil {
                        Button(Ollama.appURL == nil ? "Install" : "Start") { Task { _ = await app.installOllama() } }
                            .buttonStyle(GhostButton(tint: Theme.violet))
                            .disabled(app.osTooOld || app.ollama == .checking)
                    }
                }
                if let job = app.ollamaJob { Bar(fraction: job.fraction).padding(.leading, 34) }
                step(2, "A model", modelDetail, done: app.hasModel, busy: !app.pulls.isEmpty) { EmptyView() }
                step(3, "Allow Infinite Trading", siteDetail, done: app.siteAllowed, busy: app.connecting) {
                    if app.running && !app.siteAllowed && !app.connecting {
                        Button("Allow") { Task { _ = await app.connectSite() } }
                            .buttonStyle(GhostButton(tint: Theme.violet))
                    }
                }
            }
        }
    }

    var ollamaDetail: String {
        if let job = app.ollamaJob { return job.status }
        switch app.ollama {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed · free, by ollama.com"
        case .stopped:
            return Ollama.appURL == nil ? "Ollama CLI is off · Install adds the app" : "Installed, not running"
        case .running(let v): return "Running · v\(v) · port \(Ollama.port)"
        }
    }

    var modelDetail: String {
        if let (id, job) = app.pulls.first { return "\(id) · \(job.status)" }
        let chat = app.installed.filter { !$0.name.contains("embed") }
        return chat.isEmpty ? "Pick one on the right" : chat.map(\.name).prefix(2).joined(separator: ", ")
            + (chat.count > 2 ? " +\(chat.count - 2)" : "")
    }

    var siteDetail: String {
        if app.connecting { return "Allowing the site and restarting Ollama…" }
        if app.siteAllowed { return "infinitetrading.io can reach Ollama" }
        return app.running ? "Lets the site talk to Ollama, nothing else" : "Needs Ollama running"
    }

    func step<A: View>(_ n: Int, _ title: String, _ detail: String, done: Bool, busy: Bool,
                       @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(done ? Theme.green.opacity(0.18) : Color.white.opacity(0.06))
                Circle().strokeBorder(done ? Theme.green : Theme.stroke)
                if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.green) }
                else { Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(2)
            }
            Spacer(minLength: 4)
            action()
        }
    }
}

// MARK: Main pane

enum Filter: String, CaseIterable { case fits = "Fits my Mac", all = "All models", installed = "Installed" }

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @State private var filter: Filter = .fits
    @State private var query = ""

    var shown: [ModelInfo] {
        app.models.filter { m in
            let f = fit(m, on: app.specs, installed: app.isInstalled(m))
            switch filter {
            case .fits: if f < .slow && !app.isInstalled(m) { return false }
            case .installed: if !app.isInstalled(m) { return false }
            case .all: break
            }
            return query.isEmpty || "\(m.title) \(m.publisher) \(m.id)".localizedCaseInsensitiveContains(query)
        }
        .sorted {
            let (a, b) = (fit($0, on: app.specs, installed: app.isInstalled($0)), fit($1, on: app.specs, installed: app.isInstalled($1)))
            return a != b ? a > b : $0.rank > $1.rank
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let e = app.error {
                    Banner(text: e, color: Theme.red, icon: "exclamationmark.triangle.fill") { app.error = nil }
                }
                if let n = app.notice {
                    Banner(text: n, color: Theme.green, icon: "checkmark.seal.fill") { app.notice = nil }
                }
                if let rec = app.recommended { Hero(model: rec) }

                HStack {
                    Text("Models").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 290)
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                }

                LazyVStack(spacing: 10) {
                    ForEach(shown) { ModelRow(model: $0) }
                    if shown.isEmpty {
                        Text(filter == .installed ? "No catalog models installed yet." : "No models match.")
                            .foregroundStyle(Theme.dim).padding(30)
                    }
                }

                Text("Models download from ollama.com and run entirely on this Mac. Infinite Trading never sees your prompts unless you send them to the site.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let icon: String
    let close: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }
}

struct Hero: View {
    @EnvironmentObject var app: AppModel
    let model: ModelInfo

    var body: some View {
        let job = app.pulls[model.id]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("RECOMMENDED FOR YOUR MAC").tracking(1.2)
            }
            .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.magenta)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.name).font(.system(size: 30, weight: .bold))
                Text(model.params).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.violet)
                Text("by \(model.publisher)").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            Text(model.summary).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.85))
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.dim)
            HStack(spacing: 6) {
                ForEach(model.tags, id: \.self) { tagChip($0) }
                Chip(text: "\(formatGB(model.sizeGB)) download")
                Chip(text: "\(model.context / 1000)k context")
            }

            if let job {
                VStack(alignment: .leading, spacing: 6) {
                    Bar(fraction: job.fraction)
                    HStack {
                        Text(job.status).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        Spacer()
                        Button("Pause") { app.cancel(model) }.buttonStyle(GhostButton())
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if app.ready && app.isInstalled(model) {
                        Button { app.openAgent() } label: { Label("Open Infinite Agent", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(PrimaryButton())
                        Text("All set. This model is installed and the site is allowed.")
                            .font(.system(size: 12)).foregroundStyle(Theme.green)
                    } else {
                        Button { Task { await app.setUp(model) } } label: {
                            Label(app.isInstalled(model) ? "Connect to Infinite Trading" : "Set up with one click",
                                  systemImage: "bolt.fill")
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(app.osTooOld || app.ollamaJob != nil || app.connecting)
                        Text(plan).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.violet.opacity(0.22), Theme.magenta.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.violet.opacity(0.7), Theme.magenta.opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    var why: String {
        let s = app.specs
        let budget = Int(s.gpuBudgetGB)
        switch fit(model, on: s, installed: app.isInstalled(model)) {
        case .great:
            return s.appleSilicon
                ? "Best quality that runs fully on your GPU (\(budget) GB available) with the agent's 16k context."
                : "Best quality that stays responsive on an Intel CPU."
        case .ok: return "Best model that loads on \(Int(s.memoryGB)) GB; part of it runs on the CPU."
        default: return "Your Mac is below the usual requirements; this is the lightest option."
        }
    }

    var plan: String {
        var steps: [String] = []
        if !app.running { steps.append(Ollama.appURL == nil ? "installs Ollama" : "starts Ollama") }
        if !app.isInstalled(model) { steps.append("downloads \(formatGB(model.sizeGB))") }
        if !app.siteAllowed { steps.append("allows the site") }
        return steps.isEmpty ? "" : steps.joined(separator: " · ").prefix(1).uppercased() + steps.joined(separator: " · ").dropFirst()
    }
}

struct ModelRow: View {
    @EnvironmentObject var app: AppModel
    let model: ModelInfo
    @State private var hover = false
    @State private var confirmRemove = false

    var body: some View {
        let installed = app.isInstalled(model)
        let f = fit(model, on: app.specs, installed: installed)
        let job = app.pulls[model.id]
        let isRec = app.recommended?.id == model.id

        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.violet.opacity(0.35), Theme.magenta.opacity(0.15)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(model.name.prefix(1))).font(.system(size: 17, weight: .bold))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.name).font(.system(size: 14, weight: .semibold))
                    Text(model.params).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.violet)
                    Text(model.publisher).font(.system(size: 11)).foregroundStyle(Theme.dim)
                    if isRec { Chip(text: "Recommended", color: Theme.magenta) }
                }
                Text(model.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                HStack(spacing: 5) {
                    ForEach(model.tags, id: \.self) { tagChip($0) }
                    Text("\(model.id) · needs \(Int(model.recRAM)) GB for full speed")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim.opacity(0.8))
                        .padding(.leading, 4)
                }
                if let job {
                    HStack(spacing: 8) {
                        Bar(fraction: job.fraction)
                        Text(job.status).font(.system(size: 10.5)).foregroundStyle(Theme.dim).frame(width: 190, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    if installed { Chip(text: "Installed", color: Theme.green) }
                    else { Chip(text: f.label, color: Theme.fitColor(f)) }
                    Text(formatGB(app.installedSize(model) ?? model.sizeGB))
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.dim)
                }
                if job != nil {
                    Button("Pause") { app.cancel(model) }.buttonStyle(GhostButton())
                } else if installed {
                    Button("Remove") { confirmRemove = true }.buttonStyle(GhostButton(tint: Theme.red))
                } else {
                    Button("Download") { Task { _ = await app.download(model) } }
                        .buttonStyle(PrimaryButton(compact: true))
                        .disabled(f <= .tooLarge || app.osTooOld)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isRec ? Theme.magenta.opacity(0.45) : Theme.stroke))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .confirmationDialog("Remove \(model.title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await app.remove(model) } }
        } message: {
            Text("Frees \(formatGB(app.installedSize(model) ?? model.sizeGB)). You can download it again any time.")
        }
    }
}

