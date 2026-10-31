# Alera compatibility audit

The upstream base is SoFluffyOS/xterm2 `2a339558ba103e38a304a4eda7c984b45c47e186` (5.3.0). `next` is this fork's default integration branch. `master` is an exact mirror of the upstream default branch; sync the fork into `master`, then separately review any integration into `next`. Both branches are permanent. Preserve tags and releases during branch cleanup. This fork is consumed through Git submodules and is not published on pub.dev.

## xterm2 5.4.0 integration baseline (2026-10-31)

The local integration branch `chore/sync-xterm2-5.4-20261031` merges the upstream `5.4.0` tag and its new pure-Dart `xterm2_core 1.0.0` package. The first merge commit is `7826c7a`; Alera uses a matching local path override for both packages. This is a release candidate, not a claim of macOS native-input E2E signoff.

Upstream already incorporated Alera-derived history/resize, OSC 52 clipboard bounds, unnegotiated Shift+Enter, configurable interaction, paragraph-cache efficiency and OSC 8 hyperlink-pruning commits. It also adds Kitty private-use and release-event filtering, Windows ConPTY selection fixes, and TUI scrolling improvements. Reuse those upstream implementations rather than replaying equivalent fork commits.

Keep Alera-specific tests and narrow implementation differences for the zero-width / filled-line reflow bounds guard (`e522068`), macOS IME and candidate geometry (`3ddbd46`), Windows IME Enter handling (`84fe8a6`, `421bd10`), tab/window text-client ownership (`9f6e7cb`, `9243ed9`), Shift-click extension (`8be5c31`), and macOS native paste/Kitty KeyUp interception (`6e38263`, `6b365fc`). The upstream Kitty release fix only partially overlaps the Alera shortcut lifecycle fix.

Validation at this merge baseline: on Windows, the pure Dart core passed 694 tests; the Flutter package passed 339 tests with two platform-golden tests excluded under the fork's existing CI policy; `flutter analyze --fatal-infos` reported no issues. The two platform-golden pixel mismatches remain separate from functional regression tests. Alera's app integration tests and physical macOS/Windows IME checks are tracked separately. Avoid claiming faster execution without an independent benchmark.

Future upstream sync: compare the actual source and `git range-diff`, preserve the fork-only regression tests, verify both package versions, and test keyboard/clipboard/platform behavior before moving Alera's gitlink. A submodule commit must be reachable from a remote before a CI build or release can consume it. Do not force-push the permanent mirror and integration branches.

## Retained upstream behavior

Unicode 17, grapheme clusters, Kitty keyboard negotiation, synchronized updates, native OSC 8 links, prompt metadata, search, renderer caching and parser fast paths remain upstream implementations. Alera opts into its clipboard-only shortcut map and continues to own search and navigation. The host protocol does not change.

## Original fork commits

Each row refers to `leynier/xterm.dart` history, not a cherry-pick into this repository. Tests named below are under `test/`; the full upstream suite also runs.

| Original | Disposition | Regression evidence |
| --- | --- | --- |
| `9bfa02d` scroll-region moves | Ported through indexed swaps, including delete-lines; upstream partial-width margins retained | `alera_resize_regression_test`, `alera_legacy_buffer_test`, `src/terminal_test` |
| `fa1762d` stale alternate cells | Ported with explicit clearing on regrowth | `alera_resize_regression_test` |
| `cf22dcc` development dependencies | Replaced by upstream dependencies; validation pinned to Flutter 3.44.8 | dependency resolution and analysis |
| `aa7e2c1` stale main-buffer rows | Ported only for a live hidden-cursor TUI | `alera_resize_regression_test` |
| `36eaa4b` hidden-cursor resize | Explicit `reflowWithHiddenCursor`, true upstream/mobile, false in Alera desktop | `alera_legacy_reflow_test` |
| `e49b62f` copied column gaps | Ported while preserving wide placeholders, tabs and graphemes; upstream string expectations now include visible blank columns | `alera_legacy_line_test`, `src/core/buffer/line_test`, `src/terminal_test` |
| `375c3ab` tap-up | Upstream supplies tap-up; suppress embedding callbacks when a tracked TUI owns the click | `alera_legacy_view_test` |
| `c87aec5` composed Windows input | Replaced by upstream text-input handling | `alera_legacy_view_test`, `src/terminal_view_test` |
| `fc92ffa` narrow wide-cell reflow | Replaced by upstream reflow | `alera_resize_regression_test`, `src/core/reflow_test` |
| `eb4e231` Shift+Enter | Ported CSI-u fallback: upstream's unnegotiated sequence differs; Kitty and modifyOtherKeys keep precedence | `alera_resize_regression_test`, `src/core/input/handler_test` |
| `7615d45` mouse/clipboard integration | Upstream mouse reports plus injected copy/paste, contextual Ctrl+C, sensitivity and Shift override | `alera_legacy_view_test`, `alera_view_configuration_test`, upstream mouse tests |
| `ae511db` mouse state hardening | Upstream protocol state retained; prevent duplicate embedding click callbacks | `alera_legacy_view_test`, `src/core/mouse/reporter_test` |
| `07e28f2` erase bounds | Ported bounds checks and styled regrowth | `alera_legacy_line_test`, `alera_line_compact_test` |
| `114f36c` circular reflow origin | Replaced by upstream circular-buffer replacement | `alera_legacy_circular_test`, `alera_resize_regression_test` |
| `83ff280` short-row writes | Ported viewport repair through currentLine, covering ASCII fast writes too | `alera_resize_regression_test`, `src/terminal_stress_test` |
| `a9879be` restored cursor bounds | Ported viewport clamping, without discarding saved non-reflow coordinates | `alera_cursor_restore_test` |
| `cd7a998` restored pending wrap | Combined with upstream anchor-based reflow; preserve non-reflow saved coordinates | `alera_cursor_restore_test`, `src/terminal_test` |
| `169de2f` mobile history reflow | Explicit opt-in remains true for restored mobile history | `alera_legacy_reflow_test` and Alera mobile terminal tests |
| `ebfab96` trimmed row retention | Replaced by upstream trim release/index tracking | `alera_legacy_circular_test` |
| `14ebe14` history/parser/painter memory | Compact history rows, regrow viewport rows and safely copy absent cells; retain upstream parsing and bounded paragraph caching, with linked LRU updates and a plain ASCII cache fast path | `alera_line_compact_test`, `alera_metadata_test`, `src/ui/paragraph_cache_test`, Alera render benchmarks |
| `d35ba2c` bright white | Replaced by upstream palette handling | upstream palette/render tests and Alera theme integration |

Legacy isolated combining marks are retained through `preserveOrphanCombiningMarks: true` in Alera. Upstream's default behavior is unchanged. Graphemes attached to a preceding glyph remain upstream behavior.

## Integration controls

- `TerminalView.onPaste` and `onCopy` keep the embedding application's clipboard and image-paste policy. `mouseWheelSensitivity`, `TerminalStyle.fontWeight` and nullable `cursorBlink` preserve configurable presentation and interaction.
- `shiftOverridesMouseReporting: true` keeps Shift available for local selection even when the terminal application requests Shift capture.
- `clipboardTerminalShortcuts` retains the original clipboard/select-all bindings without enabling xterm2's navigation shortcuts.
- `Terminal.clipboardDecoder` receives the original OSC 52 selector and encoded payload before native normalization. The parser permits 128 KiB encoded clipboard payloads after a bounded header, keeps the 8 KiB limit for other OSC sequences, and rejects trailing OSC 52 fields. Alera gates the decoded callback behind its existing permission. `alera_clipboard_parser_test` covers the payload boundary and recovery after oversized split sequences.
- Alera sets `allowITerm2ClipboardCapture: false` and `allowKittyClipboard: false`. It supplies an explicit `onClipboardQuery` callback returning null, because an unset callback lets `TerminalView` install its system clipboard reader. Mobile also supplies a no-op store callback. No additional clipboard read or write protocol is enabled; focused-view regressions live in Alera's desktop/mobile suites.
- Embedders must call `Terminal.dispose()` when closing or replacing an emulator to cancel synchronized-update timers and release its resources.

## Validation

Native OSC 8 storage remains bounded at 4,096 entries. At capacity, full-buffer pruning is separated by 256 rejected allocation attempts, including when the previous scan reclaimed only one slot. Existing referenced links are retained; reclaiming erased links can be delayed by that bounded number of attempts. Reset clears the delay. `alera_hyperlink_capacity_test` covers retained links and eventual reclamation; `dart run script/hyperlink_capacity_benchmark.dart` measures repeated 1,000-link batches across capacity.

Local Linux validation uses isolated Flutter 3.44.8 / Dart 3.12.2. The unmodified upstream suite passed 742 tests with two skips and two existing failures in `TerminalView.textScaler` goldens. After compatibility changes and regression additions, 851 non-golden tests passed with two skips. The same two golden failures remain; no golden images were regenerated to hide those differences.

The two upstream golden tests are tagged `platform-golden`: CI gates all other tests and reports the golden job separately without making its known platform/SDK mismatch block compatibility changes. `flutter test` without filters still executes and reports them. Alera's migration report records application, platform and benchmark results separately.

## Mirror automation

The inherited `autotag.yml` workflow is disabled in GitHub Actions for this fork so updating the unmodified upstream `master` mirror cannot create tags. The `next` branch retains that workflow identity with a manual-only definition; ordinary pushes do not publish anything. Both permanent branches reject deletion, while mirror updates remain allowed.
