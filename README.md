# Tuck

A personal Finder + Desktop context-menu utility for macOS, written in Swift 6.

- New File (with templates)
- Open With (installed editors)
- Compress image/PDF under a selected MB target, or create ZIP
- Open Terminal Here (Ghostty or Terminal.app)
- Native SwiftUI Settings with draggable order, visibility, editable MB presets, and safe menu preview
- No network traffic or services. Originals are not overwritten.

## Build and install (macOS 14+, Apple command-line developer tools/Xcode)

```sh
./scripts/install.sh
```

If the extension isn't visible, enable Tuck under **System Settings → General → Login Items & Extensions → Finder Extensions**. Relaunch Finder if needed. Open Tuck from Applications to see Settings, or use `open 'tuck://settings'` if it is running invisibly.

The installer builds and signs an app on your own Mac. No Apple Developer account is required for the ad-hoc personal build. It does not bypass Gatekeeper for untrusted downloaded software.

**Custom MB targets:** Finder Sync context menus cannot embed sliders/text fields. Choose a size from the right-click submenu, or select **Custom Size…** to show a compact native input alert. PDFKit compression may not satisfy tight limits. It does **not** silently flatten PDF text or destroy the original. ZIP archives are lossless and have no MB guarantee.

## Diagnostics

Both processes log every stage of an action: `menu.action` → `extension.menu` → `ipc.prepared` → `ipc.dispatched` → `helper.url-received` → `helper.verified` → `helper.result`. Signing keys, signatures, authenticated URLs and file paths are never logged.

```sh
log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'
./scripts/verify-ipc.sh          # one authenticated request against a disposable directory
./scripts/verify-ipc.sh zip      # ...for another operation
```

## Status

Compiles under Swift 6, builds, signs, installs and registers the Finder extension. The authenticated extension → helper hop is verified at runtime with `scripts/verify-ipc.sh`. The four context-menu actions still need physical right-click QA on macOS; see the checklist in `AGENTS.md`.

## License / attribution

MIT. Standalone repository, not a GitHub fork. The Finder Sync integration design was informed by [nikgrbn/finder-menu](https://github.com/nikgrbn/finder-menu) (MIT, copyright 2026 nikgrbn), particularly the sandboxed extension / read-only shared-preference pattern. See `NOTICE.md`.
