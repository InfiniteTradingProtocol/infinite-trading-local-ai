# Infinite Agent Manager

A small, open-source macOS app that sets up and manages **local AI models** for the
[Infinite Agent](https://www.infinitetrading.io/infinite-agent). It recommends a
model for your Mac, installs [Ollama](https://ollama.com), downloads the model,
allows infinitetrading.io to reach it, and then lets you see and control every
local model server running on the Mac. No terminal needed.

**Don't trust, verify.** You don't need to download our build. Everything the app
does is in this repository, and you can rebuild the app yourself and prove that the
published DMG came from this source ([Verify a download](#verify-a-download)).

Download: [Releases](https://github.com/InfiniteTradingProtocol/infinite-local-ai/releases/latest) ·
Product page: [infinitetrading.io/local-ai](https://www.infinitetrading.io/local-ai) ·
macOS 13+ (Ollama itself needs macOS 14+). Windows and Linux are coming.

## What it does

**Library**
1. Reads the Mac's chip, unified memory, free disk and macOS version.
2. Recommends the highest-quality model that runs fully on the GPU with the
   agent's 16k context. Metal gets about ⅔ of unified memory, or ¾ above 36 GB.
   Intel Macs get small models that don't need a thinking step. Each model
   shows a fit badge.
3. Installs Ollama when it's missing. It downloads the official app from
   ollama.com and installs it only if `codesign --strict`, Gatekeeper
   (notarized) and Ollama's Developer ID team `3MU9H2V9Y9` all pass.
4. Downloads models through Ollama's `/api/pull`, showing progress. Pausing
   keeps finished layers, so the next download resumes.
5. Allows the site, as in the site's own setup guide. It adds
   `https://www.infinitetrading.io` and `https://infinitetrading.io` to
   `OLLAMA_ORIGINS` (keeping existing entries) and restarts Ollama, then checks
   the result with a real CORS request.
6. Opens the Infinite Agent. On the site, choose Ollama → Connect.

**Speed**: every model shows how fast it will run on *this* Mac: tokens per
second while writing, time to the first word for the agent's ~3k-token prompt,
and time for a typical answer. Very slow models are flagged in red, and
downloading one asks for confirmation. Estimates start from a per-chip table
(memory bandwidth and GPU FLOPS for M1 to M5 and Intel). **Test speed** runs a
model you already have through Ollama's own timers, calibrates every estimate
to your Mac, and records measured speeds per model. See
[Speed estimates](#speed-estimates).

**Updates**: checks at launch and every 6 hours.
- **Sources, in order:** GitHub releases (public repo), the site feed
  `infinitetrading.io/downloads/latest.json`, then the GitHub CLI if you're
  signed in (`gh auth login`), which also works while the repository is private.
- **Checks before installing:** the release's SHA-256, a valid signature, the
  same bundle ID (and Developer ID team once notarized), and a higher version.
- **Install:** a helper swaps the app after it quits (old copy to the Trash)
  and relaunches it. This happens automatically when the window isn't in use,
  or from **Restart to update**.
- **Changelog:** What's New shows the bundled `CHANGELOG.md`.

**Keep models loaded**: **Unload idle** sets Ollama's `OLLAMA_KEEP_ALIVE`
(5 min to Never). A **pin** keeps one model in memory until you unpin it. The
app re-applies it after each request, because a request resets the idle timer.

**Running**: every local model server on the Mac: Ollama, LocalJev (Jev), oMLX,
llama.cpp, LM Studio, MLX LM, vLLM, KoboldCpp and LocalAI. Each shows port, PID,
CPU, memory, uptime and how it is managed.
- **Ollama**: every loaded model with its GPU/CPU split, context, time until
  unload and runner process (pid, runner port). You can reload, unload, keep a
  model loaded, or load another.
- **Restart**: relaunches the Ollama app, runs `launchctl kickstart -k` for
  launchd services, or re-spawns a hand-started `ollama serve` or LocalJev.
- **Change port**: Ollama uses `OLLAMA_HOST`, kept across logins; LocalJev uses
  `LOCALJEV_PORT`. If the server doesn't come back, the old setting is restored.
- **Stop**: asks for confirmation first.

**Logs**: live tail of the Ollama server, app and Homebrew logs, launchd
service logs, LM Studio, LocalJev and this app's own activity log
(`~/Library/Logs/Infinite Agent Manager/activity.log`).

### What it changes on your Mac
- `launchctl setenv OLLAMA_ORIGINS …` and, if you change the port, `OLLAMA_HOST`.
- One LaunchAgent, `~/Library/LaunchAgents/io.infinitetrading.agentmanager.ollama-env.plist`,
  that re-applies those variables (and `OLLAMA_KEEP_ALIVE`, if you set it) at login.
- `Ollama.app` in `/Applications` (or `~/Applications`), when you ask it to install Ollama.
- Its activity log, and `localjev.log` if it restarts LocalJev.

**Connection → Stop Allowing Infinite Trading** removes only what the app
added. The app has no telemetry and makes no network requests except to
ollama.com (Ollama and model downloads) and to servers on `127.0.0.1`.

### About Jev
Jev is a decision model served by [LocalJev](https://github.com/githubnext/localjev),
not an Ollama model. It answers with typed verdicts: a stance, a conviction
level, whether the question is answerable, and whether risk is elevated.
- **Where it works:** only in the site's **Market Scanner → Ask AI**; the
  Infinite Agent doesn't use it.
- **Setup:** manual. It needs Bun 1.2+, an oMLX server on Apple Silicon and
  the DiffusionGemma 26B-A4B 4-bit model (about 15 GB, estimated).
- **Confidence numbers:** self-reported by the model, not calibrated.
- **What this app does:** detects LocalJev, checks `/ready` and whether the
  site is allowed (CORS), and restarts it or changes its port. It doesn't
  install it.

## Speed estimates

Writing speed is limited by memory bandwidth: each token reads the active
weights once, plus a fixed per-token cost, so seconds per token ≈ overhead +
GB per token ÷ effective bandwidth. That's the whole
model, or only the active experts for mixture-of-experts models such as
gpt-oss and Qwen3 30B. Reading the prompt is limited by compute: tok/s ≈
effective FLOPS ÷ (2 × active parameters).

| | Table value | Source |
|---|---|---|
| Apple Silicon bandwidth | chip spec × 0.55 | llama.cpp Apple Silicon results (0.45–0.7) |
| Apple Silicon compute | GPU FP16 TFLOPS × 0.65 | same (prompt processing 0.6–0.7) |
| Per-token overhead | 8 ms (Apple GPU), 65 ms (Intel CPU) | fitted to the benchmarks below |
| Intel Macs | 17.3 GB/s, 315 GFLOPS | fitted to an i7-8700B (6-core, DDR4-2666), 1B to 32B |

Models that spill out of Metal's memory share run at about 45% of that speed
for writing and 35% for prompt processing. Speed tiers: **fast** ≥ 15 tok/s;
**OK** ≥ 7; **slow** under 7, or over 40 s to the first word; **very slow**
under 3, or over 2 min to the first word. Expect ±30% until you run the speed
test.

Measured on the Intel Mac mini this was built on (i7-8700B, 64 GB, Ollama 0.40.13, CPU only):

| Model | Size | Writes (tok/s) | Reads prompt (tok/s) | First word, 3k-token agent prompt | Typical answer (250 tokens) | App estimate (writes) |
|---|---|---|---|---|---|---|
| qwen2.5-coder:1.5b | 0.99 GB (1.5B Q4_K_M) | **16.4** | 91 | 33 s | 48 s | 8.2 |
| llama3.2:1b | 1.32 GB (1.2B Q8_0) | **9.0** | 99 | 30 s | 58 s | 7.1 |
| llama3.2 (3B) | 2.02 GB (3.2B Q4_K_M) | **5.5** | 52 | 57 s | 1.7 min | 5.5 |
| qwen2.5-coder:7b | 4.68 GB (7.6B Q4_K_M) | **3.4** | 22 | 2.3 min | 3.5 min | 3.0 |
| llama3.1 (8B) | 4.92 GB (8.0B Q4_K_M) | **3.4** | 18 | 2.8 min | 4.0 min | 2.9 |
| qwen2.5-coder:14b | 8.99 GB (14.8B Q4_K_M) | **1.7** | 10 | 4.9 min | 7.3 min | 1.7 |
| command-r (32B) | 18.72 GB (32.3B Q4_0) | **0.7** | 5 | 10.4 min | 16.5 min | 0.9 |

Reading is 6–10× faster than writing on a CPU, but the agent's first prompt is long, so time to the first word dominates. Follow-up questions reuse Ollama's prompt cache and start much sooner. On Apple Silicon the same models run 5–20× faster on the GPU.

## Build from source

Requirements: macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).
There are no third-party dependencies.

```sh
git clone https://github.com/InfiniteTradingProtocol/infinite-local-ai
cd infinite-local-ai
bash mac/build.sh
open "build/Infinite Agent Manager.app"
```

This compiles `mac/Sources/*.swift` for arm64 and x86_64 with `swiftc`, merges
them with `lipo`, signs the app ad-hoc and writes three DMGs to `dist/`:
`InfiniteAgentManager-<version>.dmg` (universal, Apple Silicon and Intel), and
the single-architecture `-apple-silicon.dmg` and `-intel.dmg`, each holding one
architecture's slice of the same executable.

| Path | What |
|---|---|
| `mac/Sources/Catalog.swift` | Model catalog, Mac specs, fit and recommendation rules |
| `mac/Sources/Ollama.swift` | Ollama API, verified install, launchd environment, site access |
| `mac/Sources/Manager.swift` | Server discovery (`ps`, `lsof`, `launchctl`), restart/stop/port, Jev, logs |
| `mac/Sources/*Views.swift`, `App.swift` | SwiftUI interface |
| `catalog/models.json` | The model list (shared with the future Windows/Linux apps) |
| `scripts/verify.sh` | Rebuild and compare against a downloaded DMG |
| `.github/workflows/build.yml` | CI build, release and attestation |

## Verify a download

Each release is built by GitHub Actions from a tagged commit. The release page
lists that commit, the DMG's SHA-256 and the toolchain used.

1. **The file is the one we published:**
   `shasum -a 256 InfiniteAgentManager-<version>.dmg` must match the release.
2. **It was built by this repository's workflow from that commit** (Sigstore build provenance;
   only while the repository is public, because GitHub doesn't keep attestations for private repositories on our plan):
   ```sh
   gh attestation verify InfiniteAgentManager-<version>.dmg --repo InfiniteTradingProtocol/infinite-local-ai
   ```
3. **The app inside is exactly this source:**
   ```sh
   git checkout v<version>
   bash scripts/verify.sh ~/Downloads/InfiniteAgentManager-<version>.dmg   # or the -apple-silicon / -intel DMG
   ```
   This rebuilds the executable and compares it with the DMG's, per architecture.
   Two parts are normalized first:
   - the code signature: the binary is re-signed ad-hoc, then the signature is removed;
   - `LC_UUID`: Apple's linker writes a random UUID on every link, so it is zeroed.

   Everything else must match byte for byte. You need the same Swift toolchain
   as the release. With a different Xcode the bytes differ even though the
   source is the same.

The app is ad-hoc signed, not notarized by Apple. The first time you open it,
right-click → Open. Notarized builds will follow when a Developer ID is set up
(`DEVELOPER_ID=… NOTARY_PROFILE=… bash mac/build.sh`).

## Tests

```sh
# Recommendation rules (also run in CI)
xcrun swiftc -swift-version 5 mac/Sources/{Catalog,Speed}.swift tests/recommend/main.swift -o build/recommend-test && build/recommend-test

# Live control test: restarts, re-ports (11434 → 11435 → 11434), stops and starts
# the Ollama on this Mac (~1 minute of downtime, restores OLLAMA_HOST)
xcrun swiftc -swift-version 5 mac/Sources/{Catalog,Ollama,Manager}.swift tests/control/main.swift -o build/control-test && build/control-test

# Render the window to PNG: --tab library|running|logs; ILA_DEMO=1 shows sample servers,
# ILA_SPECS="M4 Pro,48" simulates another Mac, ILA_HEIGHT=2400 renders taller
"build/Infinite Agent Manager.app/Contents/MacOS/InfiniteAgentManager" --snapshot /tmp/shot.png --tab running
```

## Versions

`main` holds the current version; [CHANGELOG.md](CHANGELOG.md) lists every
change. Releases are git tags with a GitHub Release. Source snapshots of the
versions released before this repository existed are in `old versions/`.

## Catalog

In `catalog/models.json`:
- `sizeGB` is the download size of the default Q4 tag.
- `minRAM` is the memory needed to load the model; it may spill to the CPU.
- `recRAM` is the memory needed to run fully on the GPU.
- `rank` is quality for the agent.

The recommendation test pins the expected pick for each memory tier. Pull
requests that add or retune models are welcome.

## License

[MIT](LICENSE)
