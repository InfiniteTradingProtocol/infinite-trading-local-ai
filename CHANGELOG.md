# Changelog

The current version is always the one in `mac/`, `catalog/` and `tests/`. From
0.3.0, every release is a git tag with a GitHub Release built by CI. 0.1.0 and
0.2.0 were released before this repository existed; their sources are in
`old versions/<version>/`. The 0.2.0 source was checked to rebuild its shipped
executable exactly (normalized).

## 0.3.0 — 2026-10-30 · Open source, Jev, verifiable builds

### Added
- **Jev (LocalJev) support.** The app detects LocalJev (a Bun process run from
  a LocalJev checkout) and its oMLX upstream, checks `/ready` and whether the
  site is allowed (CORS), and can restart LocalJev or change its port
  (`LOCALJEV_PORT`). The Library has a Jev card with use cases and
  limitations: typed verdicts only, Market Scanner Ask AI only, manual setup
  on Apple Silicon.
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
- The Jev server card no longer shows a `/v1` address.

### Changed
- `build.sh` passes `-module-name InfiniteAgentManager`, so the output path
  can't change the binary, and prints the DMG's SHA-256.

## 0.2.0 — 2026-10-30 · Infinite Agent Manager

Renamed from **Infinite Local AI** (bundle id `io.infinitetrading.agentmanager`).

### Added
- **Running** tab: every local model server on the Mac (Ollama, llama.cpp,
  LM Studio, MLX LM, vLLM, KoboldCpp, LocalAI, Jev), found from processes and
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
Kept in `old versions/0.1.0/`.
