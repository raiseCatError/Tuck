# Tuck pre-release engineering gates

Tuck is a personal-use macOS Finder Sync utility. A passing build and headless
test suite are **not** a guarantee of physical Finder integration, third-party
codec compatibility, or public distribution readiness.

## Automated build

```sh
./scripts/test-model.sh
./scripts/build.sh
./scripts/verify-ipc.sh
```

GitHub Actions runs the model/toolkit/IPC suites and ad-hoc signs the app and
Finder extension on hosted macOS. It does **not** test right-click Finder,
Desktop extension activation, permissions, VoiceOver, keyboard navigation,
multi-monitor appearance, or launch/registration on an untouched Mac.

For local development, `build.sh` and `test-model.sh` require an actual mounted
external scratch volume and fail closed instead of silently writing caches to
the internal SSD. The default search order is `/Volumes/T7Tmp`, then
`/Volumes/T7Projects`; `TUCK_SCRATCH_VOLUME` can select another mounted
`/Volumes/...` volume. GitHub-hosted runners use their own ephemeral storage.
The operating system may still write OS-managed logs or registration data.

## Engineering checklist before public release

- [ ] Complete remaining product issues with exact-head macOS CI and source review.
- [ ] Verify real Finder extension context menus and settings on the installed Mac.
- [ ] Exercise cancellation/retry/history/Undo using disposable test files.
- [ ] Verify full file hashes of originals across conversion, compression, copy
      and ZIP workflows; ensure unsafe collisions and changed outputs refuse.
- [ ] Validate optional tools (`pdfimages`, `cwebp`, `jpegli`, `qpdf`,
      Ghostscript, `7zz`) only when genuinely installed.
- [ ] Exercise supported codecs with malformed/encrypted/animated/signed inputs,
      mixed filename encodings, mounted-volume removal and low storage.
- [ ] Measure context menu construction time from
      `extension.menu-duration ms=...` logs for 1, 16, 100 and 256 selected
      items, warm and cold. Requests >256 or 64KB signed payload must refuse.
- [ ] Review all third-party license terms before bundling any executable.
      There are no downloaded tools in Tuck's installer.
- [ ] Check VoiceOver, keyboard-only and Increase Contrast/Reduce Motion.
- [ ] Verify macOS minimum version, Intel if advertised, and installation,
      update and uninstall behavior on a separate Mac user account.
- [ ] For public downloads: Developer ID team, hardened runtime, nested app/
      appex entitlements, notarization, `spctl` and Gatekeeper, signed archive,
      checksums, privacy policy, version and release notes.

**No release/tag/publish operation should run automatically.** Ad-hoc signing
works for local builds, but cannot replace Developer ID notarization for
unrestricted public distribution.

## Known operational boundaries

Tuck supports at most 256 paths and 64 KB of authenticated selection payload;
unsupported formats must be refused, never silently converted under a false
extension. ZIP extraction is deliberately conservative about encrypted,
unknown, symlink and high-expansion archives. Watched folders, if enabled, are
active while the Tuck application runs; no persistent login daemon is installed
by default. Changing or disconnecting an external volume must never silently
redirect jobs into a different directory.

The canonical open acceptance criteria live in
[the roadmap](https://github.com/raiseCatError/Tuck/issues/1).
