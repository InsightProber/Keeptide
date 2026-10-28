# Feature scope

The table below describes the planned first release. Development builds currently
include local recording, explicit start/pause controls, ignored applications,
exact capture deduplication, a recent-clips list, original-format and plain-text
copying, and a quick-access panel. The panel shows clips in a centered strip, 7, 9
or 11 in a row as set in a minimal Settings window, and steps through them with
the arrow keys or a trackpad swipe, one clip per detent with a haptic tick on a
Force Touch trackpad. It searches all content with a local full-text index,
filters by type, and previews text and images. Other capabilities, including
direct paste into other apps, remain planned. There is no application release yet.

## First release

| Area | Planned capability |
| --- | --- |
| Clipboard history | Capture supported text, rich content, images, URLs and file references, preserving original representations |
| Reusable snippets | Save a capture or create a short note, command, prompt or code fragment directly |
| Editing | Native text editing, recoverable drafts, light Markdown and preservation of the original capture |
| Quick access | A global shortcut, a centered strip of clips, keyboard navigation and explicit actions |
| Search | Fast literal full-text search, mixed-language content, short Chinese queries and useful filters |
| Organization | Flat collections with one collection per saved snippet, plus independent favorites |
| Previews | Text, image, URL and file previews; Space opens a preview when results have focus |
| Reuse | Original-format copying, plain-text copying and permission-aware automatic insertion |
| Retention | Configurable history duration, including permanent retention; saved snippets remain independent of history cleanup |
| Recovery | Recently deleted content, clear storage errors and protection against partial writes |
| iCloud | Background saving of portable content and recovery after reinstalling |
| Export | Readable text/Markdown and a content archive with a verifiable manifest |
| Privacy controls | Explicit recording, pause/resume, ignored applications and local handling of file permissions |
| Accessibility | Keyboard access, native text composition, VoiceOver and system appearance preferences |

## Product boundaries

- The application is Mac-only. The first release does not include mobile apps,
  collaboration or a dedicated multi-device workflow.
- A file reference is not a backup of the file's contents.
- iCloud mirrors current data, including deletions. It does not provide an
  unlimited version history or guarantee immediate delivery of offline changes.
- Permanent retention avoids automatic age, count or capacity eviction. If the
  disk cannot safely accept new content, recording must pause visibly.
- Saved commands are content. Reusing them must not automatically execute them.
- Detailed implementation notes and internal delivery checklists are maintained
  separately from these public product documents.

## Later exploration

Semantic search and contextual suggestions are potential second-phase features.
They require separate decisions about model execution, privacy, consent, quality
and performance. They are not first-release promises.
