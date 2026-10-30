# Infinite Local AI

Desktop app that recommends, downloads and connects a local AI model to the
[Infinite Agent](https://www.infinitetrading.io/infinite-agent) with a few
clicks and no terminal. macOS first (`.dmg`); Windows (`.exe`) will reuse
`catalog/models.json`.

## What it does

1. **Reads the Mac's specs**: chip, unified memory, free disk and macOS version.
2. **Recommends a model**: the highest-ranked catalog model that runs fully on
   the GPU with the agent's 16k context (Metal gets about two thirds of unified
   memory, or three quarters above 36 GB). Intel Macs get small models without
   a thinking step. Every model has a fit badge: Great fit / Runs, slower /
   Slow / Too large / Not enough disk.
3. **Installs Ollama** if needed. It downloads the official app from ollama.com,
   then installs it only if `codesign --strict`, Gatekeeper (notarized) and team
   `3MU9H2V9Y9` (Infra Technologies, Inc.) all pass.
4. **Downloads models** through Ollama's `/api/pull`, showing progress. Pausing
   keeps finished layers, so the next download resumes.
5. **Allows Infinite Trading** the same way the site's Ollama guide does (step 3):
   adds `https://www.infinitetrading.io,https://infinitetrading.io` to
   `OLLAMA_ORIGINS` with `launchctl setenv`, keeping any origins already there.
   It also writes `~/Library/LaunchAgents/io.infinitetrading.localai.ollama-origins.plist`
   so the setting survives logout, and restarts the Ollama app. It then checks
   the result with a real CORS request (`Origin:` header → `Access-Control-Allow-Origin`).
6. **Opens the Infinite Agent**. On the site, choose Ollama → Connect. The site
   lists `/api/tags` and selects the newest model.

"Set up with one click" on the recommended model runs steps 3 to 6 in a row.
**Connection → Stop Allowing Infinite Trading** removes only what the app added.

## Build

Requires Xcode Command Line Tools (macOS 13+ to run; Ollama itself needs macOS 14+).

```sh
bash mac/build.sh        # build/Infinite Local AI.app + dist/InfiniteLocalAI-<version>.dmg (ad-hoc signed)
```

For public distribution, sign with a Developer ID and notarize. Without this,
other Macs show "unidentified developer" and users must right-click → Open.

```sh
xcrun notarytool store-credentials itp-notary --apple-id … --team-id … --password <app-specific>
DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=itp-notary bash mac/build.sh
```

## Test

```sh
swiftc -swift-version 5 mac/Sources/Catalog.swift tests/recommend/main.swift -o build/recommend-test && build/recommend-test
"build/Infinite Local AI.app/Contents/MacOS/InfiniteLocalAI" --snapshot /tmp/ila.png   # render the window to PNG
```

## Catalog

`catalog/models.json`: `sizeGB` is the download size of the default Q4 tag.
`minRAM` loads, possibly spilling to the CPU; `recRAM` runs fully on the GPU.
`rank` is quality for the agent. Edit the catalog and rebuild; the
recommendation test pins the expected pick for each memory tier.
