# Tuck physical Finder validation (issue #3)

This checklist is a **required human macOS Finder gate**, not a claim that CI or a CLI IPC probe has clicked Finder menus. The PR macOS workflow proves Swift 6 compilation and headless tests; it does not prove Finder Sync activation or window visuals.

## Preparation

Use *disposable copies* in a dedicated folder, ideally on the mounted external scratch volume. Do not perform rename or Undo experiments on valuable originals. Record your macOS version, `git rev-parse HEAD`, Tuck app/extension version, and the location of the installed app. Do not use a source directory that could be cleaned by a compression job.

```bash
cd /Volumes/T7Projects/Projects/tuck
./scripts/build.sh
./scripts/test-model.sh
./scripts/install.sh
./scripts/verify-ipc.sh
bash ./scripts/verify-finder-environment.sh
```

Fully quit any previously launched Tuck, relaunch `~/Applications/Tuck.app`, and enable Tuck under **System Settings → General → Login Items & Extensions → Finder Extensions**. Restart Finder only if needed after changing extension registration.

## Physical matrix (record Pass/Fail with screenshots and output hashes)

| Context | Operation / expected result |
| --- | --- |
| Finder folder background | Contextual Tuck menu visible; New File creates a new file in this folder |
| Desktop empty area | Extension appears if enabled; correct Desktop-specific menu |
| Desktop file / regular Finder file | Correct selected-file actions, not background-only actions |
| Finder folder selection | Open Terminal Here opens the chosen terminal in the correct directory; ZIP creates a usable Deflate archive |
| JPEG/PNG/HEIC/PDF | Compress under 1, 2, 5, 10, 25 MB and decimal custom targets; output is **strictly less** than target × 1,000,000 bytes |
| Already-small source | A separate lossless output copy is generated and highlighted; source unchanged |
| Unsupported/unattainable limit | Clear explanation and no invalid/oversize output |
| ZIP folder and mixed files | Archive Utility extracts all entries; content hashes and relative paths match originals |
| Inspect ZIP | Search/sort and inspect sizes/dates; extract all or selected; repeated operations create distinct folders; malformed/encrypted/traversal/symlink archives refuse |
| Mixed PDF + images | Input order chooser matches resulting page order; reorder pages (a complete permutation) and split/rotate without changing originals |
| OCR scanned PDF | Searchable/selectable extracted text appears; original appearance retained |
| Image conversion | Format signature and extension agree; color/alpha/orientation survive where supported |
| Rename | Test literal find/replace, regex, prefix/suffix, numbering, extension change, swaps/cycles and collision preview; history allows safe restoration |
| Job Manager | Queued jobs progress one at a time; cancel queued and running jobs; retry failures where appropriate |
| Generated-file Undo | User-modified outputs must be **refused**, not trashed; unmodified generated copies may be moved to Trash |
| Activity | Status, partial failure, output reveal, undo and history after app restart accurate; optional Before/After image/PDF comparison reuses cached previews, source hash unchanged |
| Find duplicates | Identical-content/different-name grouped; equal-size but different-content excluded; no symlink cycling; Trash only explicitly selected unchanged copies and always preserve a survivor |
| Destinations | Add/remove/reorder saved folders; Copy To retains originals, Move To confirms, collisions resolve without overwrite, cross-volume verification retains source on failure |
| Custom Actions | Only configured compatible actions appear; a trusted disposable executable receives path argv safely; Shortcuts errors/timeouts/cancel are actionable; disabling removes submenu item |
| Recipes | Create/reorder/duplicate/edit/import/export typed image recipes, run on mixed valid/invalid inputs; final copies appear in export; intermediates cleaned; no external scratch causes safe refusal |
| Watched Folders | Opt into one test folder and recipe, create stable image, verify exactly one queued job; pause/resume, disconnect drive, avoid export loops; rule does not run when disabled or app is quit |
| Settings panes | Menu/Compression/Activity/Destinations/Automation/Recipes/Watched Folders/Applications/General headings visible after resize, scroll and sidebar changes |

### Isolation, correctness and failure tests

- SHA-256 input **before and after** copy/compression/PDF/image operations must match.
- Test filename collisions, long Unicode paths, files from different folders, 1/16/17/100/256/257 selected paths and total IPC URL length limits. Oversized requests should be explicitly rejected, never silently truncated.
- Disable an optional encoder, try an unreadable file, unmount a disposable external test volume, and cancel during a batch. There must be no corruption, overwrite or untracked published output.
- Verify closed/reopened Activity correctly marks interrupted jobs (not “Running” indefinitely). History should have restricted filesystem permissions.
- Check the Tuck extension, Settings panes, and progress window under light/dark appearance, narrow windows, keyboard navigation and VoiceOver.
- Tuck **must not** claim full automatic recovery for an operation whose executor cannot be reconstituted after restarting the app.

## Sign-off

Issue #3 stays open until a real Mac user has completed this matrix and documented evidence for the actually installed binary. Automated CI and screenshot claims from prior agents are not a substitute. Mark any unsupported condition as “Not tested” with a reason rather than silently passing it.
