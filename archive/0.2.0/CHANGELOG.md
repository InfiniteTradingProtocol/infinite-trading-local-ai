# Changelog

The current version is always the one in `mac/`, `catalog/` and `tests/` (built to
`build/` and `dist/`). Each earlier release is kept, source and DMG, in
`old versions/<version>/`.

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
