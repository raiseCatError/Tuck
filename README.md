# Tuck

**Tuck** is a native Swift 6 macOS Finder context-menu utility. Select files in Finder, open **Tuck** in the right-click menu, and run common operations without opening a heavyweight file manager.

[GitHub issues and roadmap](https://github.com/raiseCatError/Tuck/issues/1) · [Finder QA checklist](docs/finder-qa.md)

> Development status: **personal-use, under active testing**. Headless Swift 6, IPC and toolkit tests run in macOS CI; full real-world Finder workflows still require hands-on verification on a Mac. Feature availability depends on file type, installed codecs and permissions.

## Features

| Area | Current functionality |
| --- | --- |
| Compression | JPEG, PNG, HEIC, TIFF, BMP and PDF to a **strictly-under** decimal-MB target; separate, collision-safe `-compressed` output; ZIP archive creation |
| PDF Toolkit | Merge PDFs and images in a specified order, split by page/range, rotate/reorder pages, on-device Vision OCR, extract embedded images (with `pdfimages`), render pages to images |
| Image Toolkit | Convert between supported native formats and optional WebP, resize by percentage, dimensions or longest edge |
| Metadata | Inspect format, dimensions, color, EXIF/GPS, selected PDF metadata and SHA-256; create a `-stripped` copy |
| Finder conveniences | New File templates, Open With installed editors, Open Terminal Here, Copy As filename/path/URL/shell-quoted path/checksum |
| Rename | Confirmed find/replace, regex replacement, prefix/suffix, numbering and extension changes; transactional rename with rollback and source identity checks |
| ZIP Inspector | Browse and sort ZIP entries; extract all or selected files into a new folder. Encrypted, unsupported, symlink and high-risk archives are conservatively refused |
| Duplicate Finder | Exact-content file grouping using streamed hashes, review/reveal results and explicitly selected copies moved to Trash after identity rechecks |
| Destinations | Saved folder bookmarks for copy/move; collision-safe outputs, verified copy, source-preserving cross-volume move failures |
| Automation | Explicit custom executables/Shortcuts using argv isolation, typed non-destructive image export recipes, optional folder-event rules that run only while Tuck is open |
| Activity | Single-heavy-job FIFO queue, progress, pause/cancel, retry of eligible in-session failures, persisted history, verified Undo for eligible generated files and renames; opt-in image/PDF comparison for single-file compression |

### Important limits and safety

- **Original files remain untouched by default.** Compression, image conversion, metadata stripping, ZIP, recipes and PDF transformations create new outputs. Rename and Move To are explicitly confirmed before changing originals. Custom actions can modify arbitrary files and must be configured by the user.
- **Under 5 MB** means *strictly less than 5,000,000 bytes*; not 5 MiB. A requested size may be unattainable, particularly for lossless formats. No quality presets: Tuck automatically searches for the best feasible fidelity.
- Automatic Undo requires evidence that a generated output is still the same regular file (content hash and device/inode identity). A modified/replaced file is refused. Verified generated copies go to **Trash**, not permanent deletion. Older history without proofs, directories and symlinks do not qualify for automatic cleanup.
- The helper and extension authenticate requests. The current limit is **256 selected paths or 64 KB of signed payload**; exceeding it shows a warning rather than silently truncating paths.
- OCR uses Apple's local Vision framework; its recognition accuracy depends on input scans. Rebuilt documents, encrypted PDFs, digital signatures, form fields and annotations can require special handling. Do not treat OCR or metadata stripping as secure redaction.
- Image/PDF operations may only support a subset of metadata and codecs. Some outputs may differ in metadata or encoding details. Validate important documents before sharing them.
- Jobs are **cooperatively cancelled**. Some external tools cannot stop immediately. A cancelled operation may have already published outputs, which should be inspected in Activity. Restarted jobs are marked interrupted; executable closures are not persisted for automatic replay. File/folder moves do not currently offer guaranteed automatic Undo.
- External compression encoders are optional. Use tools from trusted package sources. Tuck does not silently install dependencies or send files to a cloud service.

## Build, install and uninstall

Requirements: **macOS 14+**, Swift 6 toolchain/Xcode macOS SDK, and Finder Sync extensions permitted. Apple Silicon has been tested by development and CI; other architectures need additional verification.

```bash
git clone https://github.com/raiseCatError/Tuck.git
cd Tuck
./scripts/test-model.sh
./scripts/build.sh
./scripts/install.sh
```

To use the right-click menu, open **System Settings → General → Login Items & Extensions → Finder Extensions** and enable Tuck. The installer ad-hoc signs a personal-use copy in `~/Applications/Tuck.app`. Launch the app directly to open Settings; it is designed not to need a permanent Dock window.

```bash
./scripts/verify-ipc.sh
bash ./scripts/verify-finder-environment.sh
./scripts/uninstall.sh
```

`verify-ipc.sh` tests the authenticated app/extension URL dispatch but **does not** prove the Finder menu works; follow [docs/finder-qa.md](docs/finder-qa.md) for the real UI check. Do not perform destructive rename/Undo experiments on original documents.

### Optional local tools

The compressor uses native ImageIO/PDFKit where supported and can discover supported command-line encoders such as `jpegli`, MozJPEG/`cjpeg`, `oxipng`, `pngquant`, `qpdf`, Ghostscript, and `7z` for standard Deflate ZIP. Authentic embedded PDF raster extraction requires Poppler's `pdfimages`; WebP conversion can use `cwebp`. Missing optional executables may disable particular formats or fall back to native codecs.

**Packaging warning:** Do not bundle a third-party executable into a redistributable build without checking its current license, notices and distribution requirements. They are not bundled in this repository.

## Diagnostics and development

The app uses an authenticated `tuck://perform` hop from Finder Sync to the helper. Structured logs use the `dev.raisecaterror.tuck` subsystem and should never include signed URLs, authentication keys or private file paths.

```bash
log stream --level info --predicate 'subsystem == "dev.raisecaterror.tuck"'
./scripts/verify-ipc.sh
./scripts/test-model.sh
```

Local **development** scripts verify a mounted T7 scratch volume for Swift caches and temporary test binaries and refuse internal fallback. Recipe processing also refuses to start without mounted external staging. Runtime compression can still fall back to macOS temporary storage or the source folder; it is **not** yet a global external-only guarantee. See [release-readiness](docs/release-readiness.md) for the current limits and release gates.

See [AGENTS.md](AGENTS.md) for development constraints. Build/test verification occurs on GitHub-hosted macOS CI for pull requests; Finder GUI integration and entitlement behavior require physical QA.

## License and credit

Tuck is licensed under [MIT](LICENSE). The Finder Sync architecture was informed by `nikgrbn/finder-menu` (MIT). See [NOTICE.md](NOTICE.md). There is no AI attribution in the code.
