# Feature scope

The table below describes the planned first release. Development builds
currently save new copies whenever Keeptide is open, with no pause switch, while
ignored applications and privacy filters decide what is skipped. They include
exact capture deduplication, a recent-clips list, original-format and plain-text
copying, and a quick-access panel that says why when new copies cannot be saved.
The panel shows clips as a row of cards on an opaque band, in small, medium or
large sizes as set in a minimal Settings window, which also sets how much larger
the selected card is drawn and whether the band's ends fade where more cards
continue. Each card's header is washed in its accent, the colour of its
collection or of the app it came from, and a soft light in the same colour lies
behind the selected card. The panel steps through them with
the arrow keys or a trackpad swipe, one clip per detent with a haptic tick on a
Force Touch trackpad. Clips
copied or pasted from Keeptide more than once, and used in the last 90 days,
appear to the left of the newest one, apart from the recent clips; Settings can
turn this off. The panel switches between all content, snippets and each
collection with the All | Snippets switch and the collection chips at its top
left, or with ⌘[ and ⌘]. It searches all content in the All list, and within the
chosen list otherwise, with a local full-text index, from a search that folds
into an icon at the band's right end until you type; a filter button beside it
narrows the list to favorites or to types. It previews text and images, and can
paste the selected clip, with Return or a double click, directly into the app
window it was opened from; Settings shows whether direct paste is on. Its
actions menu, or ⌘⌫, moves the selected clip or snippet to Recently Deleted, and
⌘Z puts it back while the panel stays open; in a collection's list the menu can
also take a snippet out of that collection. The native
library supports editable snippets; iCloud saving remains planned. There is no
application release yet.

Space opens a preview over the stationary quick-access band, with a brief zoom
that respects Reduce Motion. Its close button, a click on the exposed band, or
Escape dismisses the preview while preserving the current search and selection.
Escape continues through the existing search layers before closing quick access.

⇧⌘T, or **Text** in the preview's bar, shows the text in a selected image
beside its preview: the image on the left and, on the right, its text recognized
on this Mac with Apple's Vision, line by line or joined into paragraphs. A tall
image, such as a long screenshot, is read in strips so that its small text is
found. Nothing is recognized until it is asked for, and the recognized text is
kept beside its image on this Mac, not in iCloud or in exports. ⌘. stops a
recognition, and Escape closes the text before the preview. While the text
shows, Return pastes it instead of the image, through the same checks as a
clip; in a terminal it is a command, reviewed first when it has several lines
or control or invisible characters. ⌘C copies it, or the part selected, and
leaves quick access open; ⌘S saves it as a snippet of its own. A double-click
on a card, or a right-click on another card, still acts on that clip. An
image's card in quick access carries a small mark while its text is recognized
or waits its turn, once it has text, or when recognizing it failed; its help
tag and VoiceOver say which.

⌘T, or **Translation** in the preview's bar, shows a translation of the selected
text beside its preview: the text on the left and, on the right, a translation
made on this Mac with Apple's Translation into the first language in the
person's language list, each paragraph as it is done. Code, links and parts
already in that language stay as they are. Both languages must be downloaded on
this Mac, and Keeptide names any that is missing before it translates; a text
already in that language offers the next one. Nothing is translated until it is
asked for, and the translation is kept beside its text on this Mac, one per
item, not in iCloud or in exports. ⌘. stops a translation and shows what was
made, marked incomplete, which is kept unless a whole translation was kept
before. Escape closes the translation before the preview.
When translating again fails, the earlier translation stays and the column says
why; the same holds for the text in an image. While a whole translation that was
kept shows, Return pastes it instead of the text, through the same checks as a
clip; ⌘C copies a whole translation, or the part selected, and leaves quick
access open, and ⌘S saves it as a snippet of its own. A text's card in quick
access carries a "文A" mark while its translation is made or waits its turn,
once it is translated, when the translation was stopped part way, or when
translating it failed; its help tag and VoiceOver say which, with the language
of a translation or why it failed.

The reusable-library service foundation also supports saving captures, creating
plain text, prompt, code and Markdown content, preserving originals during edits,
recoverable local drafts, and independent conflict copies. The native library
provides text editing, document-local find, explicit capture saving and safe
undo of a newly saved capture, saving a capture straight into a collection,
flat collections, each snippet in as many as it is added to, and favorites,
library-wide search from the list, a
details panel for a snippet's type, collections, favorite and note, sidebar
counts from the search index, and a filter for favorites, content kinds and
source apps. Markdown
reading mode keeps source editing separate from rendering and never fetches
embedded images. Typed previews show stored URLs, bounded image resolutions and locally
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
| Quick access | A global shortcut, a band of clip cards, lists of snippets and collections, filters for favorites and types, keyboard navigation and explicit actions |
| Search | Fast literal full-text search, mixed-language content, short Chinese queries and useful filters |
| Organization | Flat collections; a snippet can belong to any number of them, plus independent favorites |
| Previews | Text, image, URL and file previews; Space opens a preview when results have focus |
| Text in images | Text recognized on this Mac in a copied image, shown beside its preview and kept locally |
| Translation | A text clip translated on this Mac, shown beside its preview and kept locally |
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
- Text recognition reads only images that were copied, and translation only the
  text of clips, when asked. Keeptide does not read the screen or other apps'
  windows.
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
