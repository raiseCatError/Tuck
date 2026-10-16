# Tuck release-readiness checklist

Tuck remains a personal-use development application until its **actual installed Finder extension and operations** have passed physical QA. A successful GitHub Actions build is not equivalent to a signed/notarized public distribution.

## Automated engineering gate

- [ ] The release candidate branch is reviewed; no unrelated changes or uncommitted generated artifacts
- [ ] `./scripts/test-model.sh` passes on a GitHub-hosted Apple Silicon Mac (Swift 6)
- [ ] `./scripts/build.sh` completes and ad-hoc signs **both** `Tuck.app` and `TuckFinder.appex`
- [ ] IPC tampering/freshness limits, 256-path rejection, ZIP traversal/selection safety, batch rename transaction, Undo refusal, recipes/watchers and cancellation regressions pass
- [ ] Third-party encoders, when available, are smoke-tested with real fixtures; missing encoders have explicit failure/fallback behavior
- [ ] Artifacts are verified by `codesign --verify --deep --strict --verbose=2`, with recorded binary SHA-256 and source Git commit
- [ ] Final feature-integrated head is checked by CI, not just independently passing historical PRs

CI currently exercises headless test suites and compiles/signs the app + Finder extension. It does **not** drive the actual Finder menu, exercise VoiceOver or automatically notarize.

## Physical macOS gate

See [finder-qa.md](finder-qa.md). On an installed candidate, validate all supported menu types, new action panes, long/Unicode paths, ambiguous and unavailable file types, missing optional codecs, actual ZIP decompression, Undo and source hashes. Specifically test:

- [ ] macOS version and architecture actually used for installation, including Intel if claiming support
- [ ] Finder extension registration, fresh install, upgrade and uninstall without deleting user settings/history unintentionally
- [ ] Menu preference changes visible after disabling/enabling extension; Desktop and folder/file selection
- [ ] Settings headings under the titlebar, window resize, light/dark, keyboard-only focus, VoiceOver, high contrast and reduced motion
- [ ] Long jobs, queue pause/resume, cancellation before/after published output, crash/restart interrupted history
- [ ] Copy/Move on separate volumes, disconnected external destination, filename collisions, source identity changes, and refused Undo on modified output
- [ ] ZIP selector rejection, partial extraction and bad archives without filesystem escape
- [ ] Custom actions with quoted/Unicode/dash-prefixed filenames; consent, revocation, cancellation, timeout
- [ ] Saved image recipes and watched folders with rapid copies, delayed writes, duplicate notifications, rename storms, recipe deletion, pause/resume, unmount and restart

Use *disposable files* and record failures with the installed app's source commit. Do not check a box based solely on a code review.

## Privacy and security

- Local file transformations only by default. No cloud upload/AI processing is required.
- App/extension IPC uses authenticated short-lived requests. Avoid logging signed URLs, shared keys, original private paths or arbitrary custom-script stdout.
- Finder Sync should not execute heavy operations during menu construction. Record measured warm/cold menu latency for 1, 16, 17, 100, 256 and a 1,000-item refusal.
- Shell commands are never formed by concatenating selected filenames. User-authorized executables/Shortcuts are **not sandboxed**: explicit consent matters.
- Generated outputs should be staged, collision safe and verified. The app must refuse destructive cleanup when file identity cannot be established.
- Note the current 256-path/64 KB IPC limit, conservative ZIP compatibility, 8 GB developer-machine memory budget, and temporary-storage fallbacks.

## Signing and public release

**Local builds:** `./scripts/build.sh` applies an ad-hoc signature. This is sufficient for personal evaluation where macOS permits it, not a substitute for Developer ID distribution.

**Public distribution (not configured):** obtain the account's Developer ID Application identity; review Finder Sync extension entitlements, hardened runtime, optional bundled executable licenses, and bundle identities; sign nested code first; package the app; submit for Apple notarization and staple the accepted ticket. Verify Gatekeeper on a fresh Mac. Do not invent certificates or notarization credentials, or claim these steps were performed.

Neither `scripts/build.sh`, `scripts/install.sh`, nor CI publishes to a release store, tags Git, notarizes, or uploads artifacts for public distribution. If distributing optional CLI tools, check each copyright/license and signing requirement separately.

## Suggested release record

When *all* gates pass and the maintainer approves a release, record:

- Version, Git commit, release date, tested macOS version(s) and architecture(s)
- CI workflow run, exact binary SHA-256 checksums, optional codec versions
- Summary of user-visible changes and remaining known limitations
- Physical Finder QA evidence and any issues deliberately deferred
- Signing/notarization status accurately labelled as ad-hoc, Developer ID, or notarized

**Release blocker policy:** never label the build production-ready while physical Finder verification, signing requirements for the proposed distribution channel, or a known data-loss bug remain unresolved.
