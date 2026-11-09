import SwiftUI

// "What's New": the bundled CHANGELOG.md, rendered as headings and bullets.
// Opens by itself once after the app updates to a new version.

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    private let blocks: [(kind: Character, text: String)] = ChangelogView.parse()

    static func parse() -> [(Character, String)] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [("p", "The changelog isn't bundled with this build.")]
        }
        var out: [(Character, String)] = []
        var started = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## ") { started = true; out.append(("h", String(line.dropFirst(3)))); continue }
            guard started else { continue } // skip the file's preamble
            if line.hasPrefix("### ") { out.append(("s", String(line.dropFirst(4)))) }
            else if line.hasPrefix("- ") { out.append(("b", String(line.dropFirst(2)))) }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(("_", "")) }
            else if let last = out.last, last.0 == "b" || last.0 == "p" {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces) // wrapped line
            } else { out.append(("p", line)) }
        }
        return out.filter { $0.0 != "_" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.system(size: 20, weight: .bold))
                    Text("Infinite Agent Manager \(Updater.current)").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButton(compact: true)).keyboardShortcut(.defaultAction)
            }
            .padding(22)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                        switch b.kind {
                        case "h":
                            Text(b.text).font(.system(size: 15, weight: .bold)).padding(.top, 14)
                                .foregroundStyle(Theme.violet)
                        case "s":
                            Text(b.text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundStyle(Theme.dim).padding(.top, 4)
                        case "b":
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Theme.magenta.opacity(0.8)).frame(width: 4, height: 4).padding(.top, 7)
                                Text(markdown(b.text)).font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                            }
                        default:
                            Text(markdown(b.text)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 560)
        .background(Theme.bgTop)
        .preferredColorScheme(.dark)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

/// Sidebar footer: version, update status and actions.
struct UpdateFooter: View {
    @EnvironmentObject var updates: UpdateModel
    @EnvironmentObject var nav: Nav

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let u = updates.available, updates.staged != nil {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.green)
                    Text("Version \(u.version) is ready").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Restart to update") { updates.installNow() }.buttonStyle(PrimaryButton(compact: true))
                }
            } else if let u = updates.available {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Theme.violet)
                    Text("Version \(u.version) is available").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Update") { updates.update() }.buttonStyle(PrimaryButton(compact: true)).disabled(updates.busy)
                }
            }
            Toggle("Install updates automatically", isOn: $updates.autoInstall)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Theme.dim)
                .help("When off, nothing is downloaded or installed until you click Update.")
            HStack(spacing: 6) {
                Text("v\(updates.current)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if updates.busy { ProgressView().controlSize(.small).scaleEffect(0.55) }
                Text(updates.progress.map { String(format: "Downloading %.0f%%", $0 * 100) } ?? updates.status)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail)
                    .help(updates.status)
                Spacer(minLength: 4)
                Button { Task { await updates.check(userInitiated: true) } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Check for updates").disabled(updates.busy)
                Button { nav.showChangelog = true } label: { Image(systemName: "list.bullet.rectangle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("What's new")
            }
        }
    }
}
