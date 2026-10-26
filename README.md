# Keeptide

**Keep useful content close.**

Keeptide is a native macOS clipboard history and reusable snippet library being
designed for the things you reach for every day: commands, code fragments,
prompts, links, images, and short notes.

Bring up a compact panel to find and reuse content without leaving your work.
Open the library when you want to edit, organize, or read. Save a useful capture
as a snippet, or write one directly.

> **Status: pre-implementation.** This repository currently contains the product
> direction, architecture overview, roadmap, and contributor guidance. There is
> no application download or buildable Xcode project yet. The capabilities below
> are planned for the first release.

## Designed for the Mac

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
