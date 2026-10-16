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

## Status

Development starter, **not yet compiled or physically QA-tested on macOS**. Swift 6 syntax and shared-model compilation are checked in the source-generation environment. Check `AGENTS.md` for the physical QA checklist.

## License / attribution

MIT. Standalone repository, not a GitHub fork. The Finder Sync integration design was informed by [nikgrbn/finder-menu](https://github.com/nikgrbn/finder-menu) (MIT, copyright 2026 nikgrbn), particularly the sandboxed extension / read-only shared-preference pattern. See `NOTICE.md`.
