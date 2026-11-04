# Keeptide

**Keep useful content close.**

Keeptide is a native macOS clipboard history and reusable snippet library being
designed for the things you reach for every day: commands, code fragments,
prompts, links, images, and short notes.

Bring up a compact panel to find and reuse content without leaving your work.
Open the library when you want to edit, organize, or read. Save a useful capture
as a snippet, or write one directly.

> **Status: early development.** The native foundation includes a menu-bar app,
> a quick-access panel, a library window, and a separate system test host.
> The storage foundation provides local persistence, content validation, and
> consistent reads. Local recording now preserves complete clipboard formats,
> deduplicates exact copies, and provides a recent-clips list with copy-back.
> The quick-access panel is a wide translucent band that holds a row of large
> cards: the clips you use most, then the newest and older ones. Each card
> shows the clip itself under a band in its source app's color, with the clip's
> details below. The selected card is drawn larger, with its neighbors moved
> aside. It starts on the newest card, and the cards slide with it to keep it
> in the middle except near either end of the row. Each end of the band fades
> while more cards continue past it. Clips you've copied or pasted from
> Keeptide more than once, and used in the last 90 days, appear to the left of
> the newest card, set apart by a divider and marked by icons below the cards;
> a search lists them all together. The search folds into an icon at the band's
> left end until you type. The arrow keys step one card at a time, and a
> trackpad swipe moves one card per detent with a haptic tick on a Force Touch
> trackpad. Settings covers the quick-access appearance, global shortcut,
> recording and privacy, local retention, and the truthful availability of
> features that are not enabled in the current build.
> The panel browses recent clips, searches all content through a rebuildable local
> full-text index (including one- and two-character Chinese queries), previews
> text and images, and copies the selected item in its original formats or as
> plain text. With the Accessibility (send keys) permission, it can paste the
> selected clip directly into the app window it was opened from; without it,
> Return copies. If that window changed, or anything is uncertain, it copies
> instead and says so. Keeptide sends the paste and does not confirm that the app
> received it. In a terminal, text is pasted as plain text without its trailing
> newline, and a multi-line command, or one with control or invisible
> characters, is confirmed first. Keeptide never runs commands. The native snippet
> editor is implemented; iCloud saving is still planned. There is no end-user
> release yet.

The snippet service foundation supports saving a capture without duplicating its
payload, independent text and Markdown snippets, explicit copies, and edits that
preserve the original capture. Local drafts support restart recovery and protect
concurrent edits by saving conflicting content separately. These services are
covered by native tests. The library adds recoverable editing, document find,
search, explicit saving, collections, favorites, and quick-access save and open
actions. Markdown has a native reading mode that preserves its editable source.
Image previews offer fitted and actual-size views, with explicit loading for
larger originals. URL previews use stored information and open links only when
requested. File previews use local authorization and system Quick Look.
History retention is configurable, including forever. Recently Deleted supports
restoration and explicit permanent removal, while saved snippets retain their
own content. Storage warnings are advisory, and disk-full recovery preserves
primary content and drafts.
The File menu exports the visible library or exact selected items into a new,
verified local directory. Archives preserve portable source formats alongside
readable text or Markdown; local file references require relocation. Export is
a local snapshot, not an iCloud backup or an import-and-restore workflow.

## Designed for the Mac

The following capabilities describe the planned first release; only the
capabilities listed above are implemented today.

- A focused quick-access panel and a native library window.
- Keyboard-first navigation with predictable focus and text editing.
- Restrained Liquid Glass, system typography, and accessible reading surfaces.
- Fast text search, including short Chinese queries and mixed-language content.
- Original-format clipboard reuse and editable snippets with light Markdown.
- Simple collections, favorites, previews, and configurable history retention.
- Local-first storage with background iCloud saving and reinstall recovery.

The first release targets **macOS 26 and later**, initially on Apple silicon.
It focuses on one Mac. A dedicated experience across multiple devices is outside
the first-release scope.

## Project documents

| Document | Contents |
| --- | --- |
| [Feature scope](docs/features.md) | Planned first-release capabilities and boundaries |
| [Architecture](docs/architecture.md) | Native interfaces, content storage, search, and cloud boundaries |
| [Roadmap](docs/roadmap.md) | Capability milestones and future direction |
| [Contributing](CONTRIBUTING.md) | Project status, contribution workflow, and documentation policy |
| [Agent instructions](AGENTS.md) | Shared project guidance for Codex and Claude Code |

## Development

Open `Keeptide.xcodeproj` in full Xcode with the macOS 26 SDK or later and select
the shared `Keeptide` scheme. The project uses Swift 6 and Apple frameworks;
Command Line Tools alone cannot run its XCTest suite.

The main developer checks are:

```sh
./scripts/verify.sh all
./scripts/verify.sh analyze
./scripts/benchmark.sh
./scripts/benchmark.sh --million
```

`verify.sh all` runs native tests, a Release build, and a Debug build with Swift
warnings treated as errors. `analyze` runs Xcode's static analyzer. The default
benchmark uses a fixed 10,000-item correctness oracle and measures SearchService
with 100,000 synthetic items in a Release test build. The one-million-item run is
an explicit stress-test opt-in. It is service-level evidence only: it does not
measure quick-access rendering, input latency, or UI first-frame time. Detailed
benchmark logs, result bundles, and JSON reports stay under the ignored
`.local/benchmarks/` directory. See [Contributing](CONTRIBUTING.md) for focused
commands and validation boundaries.

Recording starts on first launch, and the welcome explains how to pause it.
**Pause Recording** in the menu-bar menu or the library stops collecting new
copies, and **Resume Recording** there starts it again; Settings has the same
switch. While recording is paused, the quick-access panel says so, and its
**⋯** menu offers **Resume Recording**; when recording stops for another
reason, the panel says why. Ignored applications can be configured in the
library. Source attribution uses observed foreground-application changes and is
best effort; it cannot authenticate which application wrote the clipboard.

Recording preserves whole items and their available representations. Private or
transient content is skipped when the source marks it accordingly. A copy above
50 MiB, or one whose advertised formats cannot all be read, is skipped with a
visible status. Clipboard bodies are read in an isolated helper process so a
slow or faulty provider does not block the interface. Rapidly replaced clipboard
contents may not be captured. Detail text previews show a bounded prefix.
The library searches recent clips and saved snippets. History retention, Recently
Deleted, restoration, and explicit permanent removal are implemented locally.
File references remain local and are not backups of
the referenced files. File preview permissions stay on this Mac. When a local
reference is missing, supported references can be explicitly reattached; older
references that cannot be validated must be copied again.

Automated capture tests use isolated named pasteboards and temporary libraries.
They verify local format preservation, capture policy, and copying. The general
clipboard's Allow / Ask / Deny permission flow still needs dedicated acceptance
validation; named-pasteboard tests do not establish that behavior.

## Principles

Content should remain available offline. Keeping a snippet should protect it from
history cleanup. Editing it should preserve the original capture. Storage warnings
should be visible, and permanent retention should mean no automatic eviction.

iCloud is intended to mirror current content in the background and help restore
the library after reinstalling. It is not a historical backup service: deletions
can propagate, and unsent local changes cannot be recovered from the cloud.

AI-assisted retrieval and contextual suggestions are a future direction. The
first release concentrates on a reliable, responsive native foundation.

## License

Keeptide is licensed under the [Apache License 2.0](LICENSE).
See [NOTICE](NOTICE) for the project copyright notice.
