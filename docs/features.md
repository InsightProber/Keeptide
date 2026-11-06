# Feature scope

The table below describes the planned first release. Development builds
currently save new copies whenever Keeptide is open, with no pause switch, while
ignored applications and privacy filters decide what is skipped. They include
exact capture deduplication, a recent-clips list, original-format and plain-text
copying, and a quick-access panel that says why when new copies cannot be saved.
The panel shows clips as a
row of large cards in a wide band, in small, medium or large sizes as set in a
minimal Settings window, which also sets how much larger the selected card is
drawn and whether the band's ends fade where more cards continue. The panel
steps through them with the arrow keys or a trackpad swipe, one clip per detent
with a haptic tick on a Force Touch trackpad. Clips copied or pasted from
Keeptide more than once, and used in the last 90 days, appear to the left of
the newest one, apart from the recent clips; Settings can turn this off. The
panel searches all content with a local full-text index from a search that
folds into an icon at the band's left end until you type, filters by type,
previews text and images, and can paste the selected clip, with Return or a
double click, directly into the app window it was opened from; Settings shows
whether direct paste is on. The native library supports editable snippets;
iCloud saving remains planned. There is no application release yet.

Space opens a preview over the stationary quick-access band, with a brief zoom
that respects Reduce Motion. Its close button, a click on the exposed band, or
Escape dismisses the preview while preserving the current search and selection.
Escape continues through the existing search layers before closing quick access.

The reusable-library service foundation also supports saving captures, creating
plain text, prompt, code and Markdown content, preserving originals during edits,
recoverable local drafts, and independent conflict copies. The native library
provides text editing, document-local find, explicit capture saving and safe
undo of a newly saved capture, flat collections and favorites. Markdown reading
mode keeps source editing separate from rendering and never fetches embedded
images. Typed previews show stored URLs, bounded image resolutions and locally
authorized files. Full input-method and accessibility acceptance remains a
release gate. History now has configurable retention, a seven-day Recently
Deleted window and explicit permanent removal. Settings report allocated storage
and let users configure or disable advisory warnings. Saved snippets protect
referenced content; permanent retention has no hidden count or size quota.
Local export creates a new directory containing portable originals, readable
derivatives and an independently verified manifest. It preserves exact selected
versions, supports cancellation before publication, and never overwrites an
existing destination. File references carry relocation metadata without local
paths or permissions. Archives are local snapshots; cloud recovery remains
planned.

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
| Privacy controls | Ignored applications and privacy filters decide what is skipped, with no pause switch; a visible notice while new copies cannot be saved; local handling of file permissions |
| Accessibility | Keyboard access, native text composition, VoiceOver and system appearance preferences |

## Product boundaries

- The application is Mac-only. The first release does not include mobile apps,
  collaboration or a dedicated multi-device workflow.
- A file reference is not a backup of the file's contents.
- iCloud mirrors current data, including deletions. It does not provide an
  unlimited version history or guarantee immediate delivery of offline changes.
- Permanent retention avoids automatic age, count or capacity eviction. If the
  disk cannot safely accept new content, new copies are not saved, and Keeptide
  says so until there is room.
- Saved commands are content. Reusing them must not automatically execute them.
- Direct paste needs the Accessibility (send keys) permission, granted in System
  Settings; without it, Return copies. Keeptide checks the front app and window
  before it sends the paste and again after the panel hides. When they changed,
  or anything is uncertain, it copies instead and says so. It sends the paste and
  does not confirm that the app received it.
- When the target is a terminal, text is pasted as plain text only, and its
  trailing newline is removed. A multi-line command, or one with control or
  invisible characters, needs confirmation first, and **Copy As-Is** in the
  actions menu copies a clip complete. Keeptide never runs commands.
- Detailed implementation notes and internal delivery checklists are maintained
  separately from these public product documents.

## Later exploration

Semantic search and contextual suggestions are potential second-phase features.
They require separate decisions about model execution, privacy, consent, quality
and performance. They are not first-release promises.

## Application preferences and welcome

The native Settings window groups appearance, keyboard shortcuts, privacy, and
cloud availability. Keeptide saves new copies from first launch; the welcome
says what it saves and what it skips, and there is no switch to turn it off.
Shortcut changes preserve the last working registration if a new choice
fails. Login-item controls reflect the operating system status. iCloud is
explicitly unavailable in the current build.
