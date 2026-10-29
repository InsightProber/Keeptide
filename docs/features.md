# Feature scope

The table below describes the planned first release. Development builds currently
include local recording, explicit start/pause controls, ignored applications,
exact capture deduplication, a recent-clips list, original-format and plain-text
copying, and a quick-access panel. The panel shows clips as a row of large cards
in a wide band, in small, medium or large sizes as set in a minimal Settings
window, and steps through them with the arrow keys or a trackpad swipe, one clip
per detent with a haptic tick on a Force Touch trackpad. It searches all content
with a local full-text index from a search that folds into an icon until you
type, filters by type, previews text and images, and can paste the selected clip
directly into the app window it was opened from. Other capabilities, including
editable snippets and iCloud saving, remain planned. There is no application
release yet.

## First release

| Area | Planned capability |
| --- | --- |
| Clipboard history | Capture supported text, rich content, images, URLs and file references, preserving original representations |
| Reusable snippets | Save a capture or create a short note, command, prompt or code fragment directly |
| Editing | Native text editing, recoverable drafts, light Markdown and preservation of the original capture |
| Quick access | A global shortcut, a band of clip cards, keyboard navigation and explicit actions |
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
- Direct paste needs the Accessibility (send keys) permission, granted in System
  Settings; without it, Return copies. Keeptide checks the front app and window
  before it sends the paste and again after the panel hides. When they changed,
  or anything is uncertain, it copies instead and says so. It sends the paste and
  does not confirm that the app received it.
- When the target is a terminal, text is pasted as plain text only, and its
  trailing newline is removed. A multi-line command needs confirmation first, and
  **Copy As-Is** in the actions menu copies a clip complete. Keeptide never runs
  commands.
- Detailed implementation notes and internal delivery checklists are maintained
  separately from these public product documents.

## Later exploration

Semantic search and contextual suggestions are potential second-phase features.
They require separate decisions about model execution, privacy, consent, quality
and performance. They are not first-release promises.
