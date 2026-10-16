# Agent notes: Tuck

- Personal-use Swift 6 macOS app. Keep changes lean; no external runtime dependencies.
- Finder Sync extension is sandboxed and **never writes files directly**. The invisible host app owns all file operations.
- The extension authenticates expiring operation payloads using a per-install key in the shared preference domain. Do not add unsigned URL operations or change file operations to shell-interpolated commands.
- Never force unwrap `UserDefaults(suiteName:)`. Foundation returns nil when the suite name equals the running bundle identifier, which is exactly the helper's own domain; `TuckPreferences.resolveStore` handles it and `Tests/PreferencesTests.swift` guards it.
- Action lifecycle diagnostics live in `Sources/Shared/Log.swift`. Watch them with `log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'`; `scripts/verify-ipc.sh` exercises the authenticated hop without the Finder UI. Never log keys, signatures, full URLs or file paths.
- Menu order, enabled actions, and size presets are in `Sources/Shared/Preferences.swift`. Both extension and Settings must use the same models.
- The Desktop blank context and selection context must be tested independently on macOS 27, including mounted volumes and cloud-provider folders.
- No NSMenuItem custom views: Finder Sync supports standard items/submenus, not custom slider controls. Custom size uses a transient native alert, not a full-window workflow.
- Originals never overwritten or deleted. If a size target cannot be met, keep the original and report failure; PDF optimization should not silently rasterize searchable text.
- `scripts/build.sh` compiles with `-swift-version 6` using Xcode's macOS SDK and ad-hoc signs the extension. Verify on macOS with `scripts/install.sh`; Linux static syntax checks are insufficient.
- `FileWork.zip` multi-selection uses `/usr/bin/zip` on same-parent items; single-file uses `/usr/bin/ditto`. Invocations use `Process` argument arrays, never a shell command string.
- Before claiming readiness: physical right-click QA on Finder background, selected file/folder, Desktop background/file, Ghostty cwd, PDF/image quality, color profile/rotation/transparency, compression failure, menu order update, hidden/no-Dock helper behavior, and editor launch.
- No tags/releases until explicit approval. Keep docs minimal.
