# Changelog

The current version is always the one in `mac/`, `catalog/` and `tests/`. From
0.3.0, every release is a git tag with a GitHub Release built by CI. 0.1.0 and
0.2.0 were released before this repository existed; their sources are in
[`archive/<version>/`](archive). The 0.2.0 source was checked to rebuild its shipped
executable exactly (normalized).

## 0.6.0 — 2026-11-08 · Chat

### Added
- **Chat** tab: talk to any local model to see how it answers and how fast it
  runs on this Mac before using it with the Infinite Agent. Works with Ollama
  and with OpenAI-compatible servers (LM Studio, llama.cpp, MLX LM, vLLM…).
  Each answer shows tokens per second, time to the first word, prompt speed and
  model load time; reasoning models show their thinking separately. Stop
  anytime; chats aren't saved. The recommended model has a **Try it in Chat**
  button.

### Removed
- Support for one experimental decision-model server, and its card, port and
  restart controls. The Running tab lists the other engines as before.

### Fixed
- The README's network note now lists update checks (GitHub and
  infinitetrading.io), and the control test's compile command includes
  `Speed.swift`.

## 0.5.3 — 2026-11-05 · Public repository

### Changed
- The source moved to
  [InfiniteTradingProtocol/infinite-trading-local-ai](https://github.com/InfiniteTradingProtocol/infinite-trading-local-ai)
  and is public. The updater checks the new address (GitHub redirects the old
  one, so earlier versions still find this update).
- Releases carry a Sigstore build-provenance attestation again:
  `gh attestation verify <dmg> --repo InfiniteTradingProtocol/infinite-trading-local-ai`.

## 0.5.2 — 2026-11-05 · Tidier updates

### Fixed
- Updates no longer leave copies behind. The downloaded disk image is deleted
  as soon as its app is checked and staged, a failed download is removed, and
  at launch the app clears anything a past update left in
  `~/Library/Caches/io.infinitetrading.agentmanager/updates` (logged with the
  space freed). The previous app version still goes to the Trash, so you can
  restore it.

## 0.5.1 — 2026-11-04 · Steadier speed tests

### Fixed
- A speed test run while the Mac was busy (another model answering, a build)
  recalibrated every estimate too slow. The test now keeps each model's
  fastest result for the estimates, and warns when the Mac was busy (load
  average above half the CPU cores) so you can run it again later.

### Changed
- The sidebar shows when updates were last checked, and where from.
- First release installed through the app's own updater.

## 0.5.0 — 2026-11-04 · Updates, keep models loaded, What's New

### Added
- **Automatic updates.** The app checks for a new version at launch and every
  6 hours. It reads, in order: GitHub releases (when the repository is public),
  the site's feed at `infinitetrading.io/downloads/latest.json`, or your signed-in
  GitHub CLI (`gh`), which works while the repository is private. Before
  installing, it checks:
  - the published SHA-256 of the download;
  - a valid signature, the same bundle ID (and the same Developer ID team once
    the app is notarized), and a higher version.

  It picks this Mac's single-architecture DMG. With **Install Updates
  Automatically** on (the default), it installs when the window isn't in use
  and nothing is running: the old version goes to the Trash and the new one
  relaunches. Otherwise **Restart to update** appears in the sidebar. Every
  step is recorded in the activity log.
- **Keep models loaded.**
  - **Unload idle** on the Ollama server card sets `OLLAMA_KEEP_ALIVE` (5 min,
    30 min, 1 h, 4 h, 24 h or Never), keeps it across logins and restarts
    Ollama to apply it.
  - **Pin** a model, in Running or Library, to keep it in memory until you
    unpin it. Each request (the site's included) resets a model's idle timer,
    so the app re-pins after requests. It loads pinned models at the site's
    16k context, so the first question doesn't trigger a reload.
- **What's New.** The changelog is in the app (menu: Infinite Agent Manager →
  What's New…, or the sidebar). It opens once after each update.
- Sidebar footer: version, update status, Check for Updates.
- `scripts/publish-site.sh`: copies a release's DMGs to the website and writes
  `latest.json`.

### Fixed
- Long model names no longer wrap in the Running tab.

## 0.4.2 — 2026-11-04 · Apple Silicon and Intel downloads

- Each release now has three DMGs: universal (`InfiniteAgentManager-<v>.dmg`,
  both architectures), plus a single-architecture DMG for Apple
  Silicon (`-apple-silicon.dmg`, arm64) and for Intel Macs (`-intel.dmg`,
  x86_64). The thin executables are byte-identical slices of the universal
  one, and each DMG is listed in SHA256SUMS.
- `scripts/verify.sh` accepts any of the three DMGs.
- The app is unchanged from 0.4.1, apart from the version number.

## 0.4.1 — 2026-11-03 · Release fix

- CI skips the Sigstore build-provenance attestation while the repository is
  private: GitHub doesn't store attestations for private repositories on the
  organization's plan, so the 0.4.0 release run stopped before publishing. The
  release notes say so, and attestations return automatically when the
  repository is public. The app is identical to 0.4.0, apart from the version number.

## 0.4.0 — 2026-11-03 · Speed estimates and speed test (tagged, not published)

### Added
- **Speed for every model on this Mac.** Each model shows tokens per second
  while writing, time to the first word for the Infinite Agent's ~3k-token
  first prompt, and time for a typical 250-token answer (plus thinking time
  for reasoning models), colored fast / OK / slow / very slow. Estimates use
  memory bandwidth for writing and compute for reading the prompt, from a
  per-chip table (M1 to M5 base/Pro/Max/Ultra, and Intel Macs) with a
  per-token overhead. Intel figures are fitted to benchmarks of 1B–32B models
  on an i7-8700B.
- **Speed test.** Runs a model you already have through Ollama's own timers
  (a cold run for prompt speed, a warm run for writing), calibrates every
  estimate to this Mac, and shows measured speeds per model. Available in the
  sidebar, and per installed model.
- **Warnings.** The recommended model shows its expected speed and a warning
  when it's slow. Very slow models are hidden from "Fits my Mac" and ask for
  confirmation before downloading.
- **Also installed.** Models pulled outside the catalog (for example
  `qwen2.5-coder`, `command-r`) now appear under Installed and All models,
  with their speed, a speed test and Remove.
- README: how the estimates work, plus measured benchmarks for this build Mac.

### Changed
- The recommendation passes over models that fit in memory but would be very
  slow (under 3 tok/s, or minutes before the first word). On an M1 with 64 GB,
  for example, it picks Qwen3 30B (mixture of experts, fast) over dense Qwen3 32B.
- The catalog's "Fast" tag is hidden where this Mac makes the model slow.
- The catalog records parameter counts (`paramsB`, plus `activeB` for
  mixture-of-experts models).

## 0.3.0 — 2026-10-30 · Open source, verifiable builds

### Added
- Support for an experimental decision-model server (removed in 0.6.0).
- **Verifiable builds.** `scripts/verify.sh` rebuilds the executable from the
  checked-out source and compares it with a downloaded DMG.
  `scripts/normalize-macho.py` zeroes the linker's random `LC_UUID`.
  `build-info.json` in the app records the version, commit and Swift toolchain.
- **CI** (`.github/workflows/build.yml`): tests and a build on every push.
  Tagged releases are built on GitHub's macOS runner, with the DMG SHA-256,
  normalized executable hashes and a Sigstore build-provenance attestation.
- MIT license, plus a `.gitignore` covering build output, DMGs, signing
  material and secrets.
- `tests/control`: a live test of restart, port change and back, stop and
  start against the Mac's Ollama.

### Fixed
- **Stop** on an Ollama run by the desktop app didn't stop it, because the
  app ignores a polite quit. Stop now escalates to a force-quit, then stops the
  server process, the same way Restart does.

### Changed
- `build.sh` passes `-module-name InfiniteAgentManager`, so the output path
  can't change the binary, and prints the DMG's SHA-256.

## 0.2.0 — 2026-10-30 · Infinite Agent Manager

Renamed from **Infinite Local AI** (bundle id `io.infinitetrading.agentmanager`).

### Added
- **Running** tab: every local model server on the Mac (Ollama, llama.cpp,
  LM Studio, MLX LM, vLLM, KoboldCpp, LocalAI), found from processes and
  listening ports. Each shows port, PID, CPU, memory, uptime and who manages it
  (Ollama app, a launchd service or a process started by hand).
- Per Ollama server: the models in memory, from `/api/ps`, with GPU/CPU split,
  context, time until unload, and the runner process (pid, runner port, resident
  memory). Each model has Reload, Unload and keep-loaded actions (5 min, 30 min,
  2 h, always). A Load model menu lists installed models.
- Server actions: Restart (app relaunch, `launchctl kickstart`, or re-spawn for
  a hand-started `ollama serve`), Stop with confirmation, and Change port. The
  port is set with `OLLAMA_HOST`, the server restarts, and the old value is
  restored automatically if it doesn't come back.
- **Logs** tab: live tail of the Ollama server, Ollama app, Homebrew Ollama,
  launchd-service, LM Studio and Agent Manager activity logs. It has a filter,
  Problems only, Hide HTTP requests (2xx/3xx) and Follow, plus Copy, Show in
  Finder and Console buttons.
- Activity log at `~/Library/Logs/Infinite Agent Manager/activity.log`. Every
  install, download, restart, port change, load or unload is recorded there.
- View menu: ⌘1 Library, ⌘2 Running, ⌘3 Logs.

### Changed
- The model catalog and setup screen moved into the **Library** tab.
- One LaunchAgent (`io.infinitetrading.agentmanager.ollama-env`) now keeps
  both `OLLAMA_ORIGINS` and `OLLAMA_HOST` across logins. The 0.1.0 agent
  (`io.infinitetrading.localai.ollama-origins`) is removed when the new one is written.
- The app follows `OLLAMA_HOST`, so setup and the site check use the configured port.
- Status polling is lighter: 3 s while Running or Logs is open, 15 s otherwise,
  and 10 s for setup.
- Small memory figures show in MB; port numbers are no longer shown with
  thousands separators.

## 0.1.0 — 2026-10-29 · Infinite Local AI

First release: Mac specs, model recommendation, 19-model catalog, one-click
Ollama install (signature-verified), model downloads, approval for
infinitetrading.io (`OLLAMA_ORIGINS`), Open Infinite Agent.
Kept in [`archive/0.1.0/`](archive/0.1.0).
