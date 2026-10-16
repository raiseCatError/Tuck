# Tuck

Tuck is a native **Swift 6 macOS Finder context-menu utility** for file compression, PDF and image operations, ZIP archives, renaming, inspection and opt-in local automation. File operations run locally, with a small Finder Sync extension dispatching authenticated requests to the Tuck application.

**Status:** development build, preparing for physical Finder QA. Automated tests and builds do not establish that every real Finder action, optional codec or macOS accessibility path has been physically validated.

[Roadmap](https://github.com/raiseCatError/Tuck/issues/1) · [Physical QA](docs/finder-qa.md) · [Release readiness](docs/release-readiness.md)

## Current functionality

| Category | Actions |
| --- | --- |
| Compression | Compress JPEG, PNG, HEIC, TIFF, BMP and PDF to a target **strictly below** a decimal-MB limit; ZIP creation |
| PDF | Merge PDFs/images in explicit order; split pages/ranges; rotate/reorder pages; OCR using local Apple Vision; render pages to PNG; extract *actual embedded raster assets* with Poppler's `pdfimages` |
| Images | Convert among supported ImageIO formats and optionally WebP; resize by percentage, dimensions or longest edge; refuse unsafe/unsupported conversions rather than silently dropping animation frames |
| Metadata | Inspect dimensions, format and supported PDF/EXIF/GPS metadata, compute streaming SHA-256; create stripped copies |
| Finder convenience | New File, Open With, Open Terminal Here; Copy As names, paths, URLs, shell-quoted paths and checksums |
| Rename | Preview and apply find/replace, regex, prefix/suffix, numbered sequence or extension change; transactional rollback and collision detection |
| Comparison | Read-only side-by-side or split-slider image/PDF previews with file-size metrics, zoom and PDF page navigation |
| ZIP inspection | Inspect and search ZIP entries; select specific entries to extract into a fresh folder after validation |
| Duplicate finder | Find *exact-content* duplicates by file identity, size and full SHA-256; user explicitly selects copies for Trash |
| Destinations | Save up to eight folder bookmarks; Copy To / Move To with collision-safe publication and confirmation before moves |
| Custom actions | Explicitly configure a user-chosen executable or macOS Shortcut; compatible Finder menu actions, confirmation, bounded execution and argv-safe file paths |
| Recipes | Save non-destructive typed **image** workflows (resize, format conversion, metadata removal) and export copies to an `export` folder |
| Watched folders | Opt-in, event-driven direct-child image processing through a saved recipe while the Tuck app is running; rule enable/disable and global pause |
| Activity & Undo | Single-worker heavy-operation queue, cancellation, limited in-session retry, per-input failures, persisted history, Reveal Output and verified Undo of eligible generated regular files or batch renames |

### Behavior and limits

- **Non-destructive by default.** Compression, PDF/image tools and recipes publish separate copies; rename and Move To are explicitly confirmed. Generated-file Undo checks content hashes and file identity before using macOS Trash. It will refuse modified/replaced outputs, unverified old history, symlinks and directories.
- **Decimal limits:** “Under 5 MB” means *less than 5,000,000 bytes*, not 5 MiB. Strict-size output might be impossible without unacceptable visual changes, especially for lossless formats; errors should be explicit.
- **IPC:** Signed Finder requests have a hard limit of **256 paths and 64 KB of payload**. Larger or long-path selections are rejected with a warning instead of being silently truncated. This is not unlimited batch processing.
- **ZIP inspector:** Supports a conservative subset of ZIP/Deflate; rejects encrypted/ZIP64, symlink entries, traversal paths and filenames that the underlying extractor could interpret as glob selectors. Inspection is limited to 10,000 entries and 2 GB expanded size. Extraction first streams the archive into a private snapshot (maximum 2 GB compressed archive size) on the selected destination volume and validates that snapshot before invoking the extractor; allow temporary space for both the snapshot and the extracted content.
- **Image/document integrity:** Animated/multiframe inputs are refused where processing would drop frames. OCR creates a searchable output but recognition is not guaranteed. Tuck is **not a secure PDF redaction utility**; digital signatures, forms, annotations, unusual metadata and color profiles can require external validation.
- **Jobs:** Cancellation is cooperative and may leave already-published outputs visible in Activity. Persisted unfinished jobs are marked interrupted after restart; Tuck does not replay a previously running executable automatically.
- **Custom actions:** Users who explicitly configure a script or Shortcut are authorizing it to operate with their own permissions. Tuck does not sandbox those user executables or guarantee they are non-destructive.
- **Recipes and watchers:** Recipes are built-in image steps only, not an arbitrary script runner. Watch rules do not install a daemon and only work while the app is running; existing files are baselined when a watch starts. Recipe execution requires mounted external scratch storage.
- **Scratch:** Normal compression may fall back to system temporary storage or the source volume when no suitable external volume is found. This is **not** an external-only guarantee.

## Build and install

**Prerequisites:** macOS 14 deployment target and a Swift 6-capable Xcode/macOS SDK. Development and hosted CI use Apple Silicon; Intel is not independently validated. No paid Apple developer membership is required for a locally ad-hoc-signed installation.

```bash
git clone https://github.com/raiseCatError/Tuck.git
cd Tuck
./scripts/test-model.sh
./scripts/build.sh
./scripts/install.sh
./scripts/verify-ipc.sh
bash ./scripts/verify-finder-environment.sh
```

The installer places the application in `~/Applications/Tuck.app`. Open it, then enable **Tuck** under **System Settings → General → Login Items & Extensions → Finder Extensions**. Fully quit an older Tuck process before testing a newly installed build.

The IPC verification script checks the authenticated URL handoff. It **does not** physically right-click Finder or prove that the installed Finder menu appears. Use the [Finder QA matrix](docs/finder-qa.md) to test the complete installed app on disposable source files.

To uninstall the application, run `./scripts/uninstall.sh`. Review its actions first; user preferences and history may be intentionally retained.

### Optional local tools

Built-in Apple ImageIO, PDFKit and Vision functionality works without cloud services. Optional, separately installed tools can improve formats or compression: `cjpegli`, `cjpeg`/MozJPEG, `jpegtran`, `oxipng`, `pngquant`, `qpdf`, Ghostscript (`gs`), `7zz`/`7z`, Poppler (`pdfimages`) and `cwebp`. Missing tools may disable specific actions or cause a native fallback with a different result. Tuck does not silently download executables.

Optional third-party binaries are **not bundled**. Check their individual distribution licenses before redistributing them.

## Diagnostics

```bash
./scripts/test-model.sh
./scripts/verify-ipc.sh
bash ./scripts/verify-finder-environment.sh
log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'
```

Tuck's IPC uses signed `tuck://perform` requests and short-lived freshness checks. Avoid copying signed request URLs or user file paths into bug reports. Logs are designed not to expose signatures and shared keys.

See [AGENTS.md](AGENTS.md) for repository development rules, [NOTICE.md](NOTICE.md) for acknowledgements and [LICENSE](LICENSE) for MIT licensing.

## Shipping

A signed-and-built app on GitHub Actions is **not notarized for public distribution**. The release checklist documents Developer ID, extension entitlements, fresh-machine installation, manual Finder/VoiceOver QA and artifact checksums. No workflow tags, notarizes or publishes builds automatically.
