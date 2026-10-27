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
> Search, snippet workflows, and iCloud saving are still planned. There is no
> end-user release yet.

## Designed for the Mac

The following capabilities describe the planned first release; only the native
foundation and local recording capabilities listed above are implemented today.

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

Run `./scripts/verify.sh all` for native tests, a Release build, and a Debug build
with Swift warnings treated as errors. See [Contributing](CONTRIBUTING.md) for focused
commands and validation
boundaries. Recording is disabled on first launch. Open the library or menu-bar
menu and choose **Start Recording** to record new copies; **Pause Recording**
stops collection. Ignored applications can be configured in the library.

Recording preserves whole items and their available representations. Private or
transient content is skipped when the source marks it accordingly. A copy above
50 MiB, or one whose advertised formats cannot all be read, is skipped with a
visible status. Rapidly replaced clipboard contents may not be captured.
The current library shows recent clips; full-library search and retention
controls are forthcoming. File references remain local and are not backups of
the referenced files. Persistent file-access authorization is not implemented.

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
