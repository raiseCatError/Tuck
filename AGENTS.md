# Agent notes: Tuck

- Personal-use Swift 6 macOS app. Keep changes lean; prefer native frameworks. Supported third-party codecs/tools are **optional** and must have explicit graceful fallbacks or actionable errors; do not silently install executables.
- Finder Sync extension is sandboxed and **never writes files directly**. The invisible host app owns all file operations.
- The extension authenticates expiring operation payloads using a per-install key in the shared preference domain. Do not add unsigned URL operations or change file operations to shell-interpolated commands.
- Never force unwrap `UserDefaults(suiteName:)`. Foundation returns nil when the suite name equals the running bundle identifier, which is exactly the helper's own domain; `TuckPreferences.resolveStore` handles it and `Tests/PreferencesTests.swift` guards it.
- Action lifecycle diagnostics live in `Sources/Shared/Log.swift`. Watch them with `log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'`; `scripts/verify-ipc.sh` exercises the authenticated hop without the Finder UI. Never log keys, signatures, full URLs or file paths.
- Menu order, enabled actions, and size presets are in `Sources/Shared/Preferences.swift`. Both extension and Settings must use the same models.
- The Desktop blank context and selection context must be tested independently on macOS 27, including mounted volumes and cloud-provider folders.
- No NSMenuItem custom views: Finder Sync supports standard items/submenus, not custom slider controls. Custom size uses a transient native alert, not a full-window workflow.
- Originals never overwritten or deleted. If a size target cannot be met, keep the original and report failure; PDF optimization should not silently rasterize searchable text.
- `scripts/build.sh` compiles with `-swift-version 6` using Xcode's macOS SDK and ad-hoc signs the extension. Verify on macOS with `scripts/install.sh`; Linux static syntax checks are insufficient.
- ZIP creation prefers a verified compatible Deflate ZIP strategy (optional 7-Zip; `/usr/bin/zip` and `/usr/bin/ditto` fallback), not a proprietary archive container. Invocations use `Process` argument arrays, never a shell command string.
- Before claiming readiness: physical right-click QA on Finder background, selected file/folder, Desktop background/file, Ghostty cwd, PDF/image quality, color profile/rotation/transparency, compression failure, menu order update, hidden/no-Dock helper behavior, and editor launch.
- Jobs must retain per-input failures and any files published before cancellation. Undo must verify original output identity before taking action; older history is not authorization to delete files.
- Explicitly check real volume mounts for large temporary/build/test files. The current compressor can fall back to system temp if no preferred volume exists; do not claim external-only scratch without enforcing it.
- No tags/releases until explicit approval. Keep docs clear and accurate.
