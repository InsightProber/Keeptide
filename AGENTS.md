# Keeptide contributor and agent instructions

This is the canonical project contract for coding agents. Codex discovers this
root `AGENTS.md`; Claude Code reads the root `CLAUDE.md`, which imports it.
Maintain one set of rules. Do not duplicate them in tool-specific files.

The repository uses Apache-2.0. Preserve the license, copyright notices and any
required third-party attribution when changing or adding material.

## Project and current state

Keeptide is a native macOS clipboard history and reusable snippet library.
The first release targets macOS 26+ with Swift 6, SwiftUI and AppKit, Core Data
backed by SQLite, a rebuildable full-text search index, and private CloudKit
storage. Native interaction quality and data reliability are release criteria.

The repository contains an early native foundation: the `Keeptide` application,
unit and UI test targets, a separate `KeeptideSystemTestHost`, and a shared Xcode
scheme. The storage foundation includes two local Core Data stores, typed
transactions, content validation, consistent snapshots, and persistent change
consumption. Local capture includes explicit recording, privacy filters, exact
deduplication, recent clips, and original-format copy-back. A rebuildable local
full-text index consumes persistent history, and the quick-access panel is a
centered band of large clip cards (small, medium or large, with trackpad ticks
and a minimal Settings window) that browses recent clips, searches all content,
previews text and images, and copies the selected item. With the Accessibility
(send keys) permission it can paste the selected clip directly into the app
window it was opened from, and it copies instead, saying so, when that window
changed or anything is uncertain. Text pasted into a terminal is plain text
without its trailing newline, and a multi-line command is confirmed first.
Keeptide never runs commands, and it does not confirm that the app received a
paste. Snippet workflows, persistent file authorization, and cloud integration
remain planned.
Planned capabilities must stay labelled until implemented and verified.

## Start here

- Read `README.md`, `docs/architecture.md`, `docs/features.md`, and
  `docs/roadmap.md` for the public product contract.
- If `.local/README.md` exists, read it to find the current Chinese design and
  implementation plan. Load only the detailed documents relevant to the task.
  Local material is optional on a fresh clone; do not invent missing decisions.
- Inspect the actual files and Git state before editing. Follow the latest
  explicit user decision and the applicable project instructions.
- Keep changes bounded and reviewable. Continue authorized, reversible work
  without repeated confirmation. Escalate destructive actions, missing authority,
  or genuinely unresolved product decisions.
- Delegate independent, bounded work when useful. Assign file ownership and do
  not revert another contributor's changes. Do not require a specific agent
  runtime, personal plugin, or model for ordinary project work.

## Documentation and publication boundary

| Material | Location | Language | Git policy |
| --- | --- | --- | --- |
| Product overview | `README.md` | English | Tracked and public |
| Overall architecture, feature scope, milestones | `docs/` | English | Tracked and public |
| Shared contributor and agent rules | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` | English | Tracked and public |
| Detailed designs, module contracts, PR plans, research, QA evidence, prototypes | `.local/docs/` | Chinese prose; original technical evidence may retain its language | Ignored; local only |
| Local indexes, tooling notes and session artifacts | `.local/` | Chinese prose | Ignored; local only |

- Public product documents describe Keeptide on its own terms and cover stable,
  high-level decisions. Keep module schemas, execution checklists, exact internal
  interfaces, detailed PR breakdowns and private investigation records local.
- Never copy private documents or evidence into a public issue, PR description,
  commit message, release, screenshot, or CI artifact. Publish a concise English
  summary of the relevant change and validation instead.
- Public documents must not link to ignored documents or personal filesystem
  locations. An inline path explaining the documentation policy is fine; a link
  requiring unpublished local content is not.
- Keep comparative research and third-party implementation observations local.
  Do not fabricate claims of novelty or provenance. Preserve any required license
  notices and attribution for code or assets that are actually reused.
- Workflow and skill defaults do not override this boundary: save detailed plans
  under `.local/docs/`, even if a workflow normally commits them under `docs/`.
- `.gitignore` does not untrack files already committed. Before every commit,
  inspect `git diff --cached --name-only` and `git diff --cached`; ensure
  `git ls-files -- .local` is empty. Never force-add private material.
- If private material was already committed, stop publication and report it;
  adding an ignore rule alone does not repair published history.

## Native macOS engineering

- Use Apple system frameworks and public APIs. Do not add dependencies or change
  the minimum OS without a concrete need and explicit authorization.
- Prefer native controls and text editing. Use AppKit where window focus, global
  shortcuts, text composition, or system integration requires it.
- Use system appearance, typography and semantic colors. Apply Liquid Glass to
  suitable navigation and controls; keep reading and editing surfaces legible.
- Every important action must work with keyboard and pointer input. Respect
  marked text, selection, undo/redo, VoiceOver, increased contrast, reduced
  transparency and reduced motion. Avoid global shortcuts that override editing.
- Keep UI state on `MainActor`. Use structured concurrency, cancellation and
  explicit isolation. Do not move managed objects across actors or perform
  large image decoding, indexing or storage maintenance on the main thread.
- Keep file membership, shared schemes and deployment settings correct when
  adding Xcode files. Check API availability on the minimum supported macOS.
- Prefer a small, clear implementation over speculative abstractions. The first
  release does not include model inference, vector storage or input monitoring.

## Storage and privacy invariants

- Core Data owns persisted content. Search indexes and preview caches are derived
  and rebuildable; never edit Core Data's private SQLite schema or support files.
- Original clipboard captures remain immutable. Editing a saved snippet must not
  alter the original capture or another independently created snippet.
- Exact capture deduplication must preserve all representations and ordering.
  Identical visible text alone does not establish identical content or identity.
- Expiration, manual deletion and permanent removal have distinct semantics.
  Retained snippets protect referenced content. Permanent retention is not a
  hidden count or storage quota; storage pressure must not silently discard it.
- CloudKit provides background mirroring and recovery. Container events do not
  prove individual records are remotely complete. Validate imported content
  before use, isolate account changes, and suspend destructive maintenance
  during initial recovery.
- Keep file permissions, bookmarks, local paths used as file references, drafts,
  indexes and usage summaries local. Do not log clipboard bodies or credentials.
  Preserve user-authored text as data; do not rewrite paths inside commands.
- Tests use synthetic content, temporary stores and isolated cloud resources.
  Never inspect or modify personal clipboard history to populate tests.
- Automatic insertion requires current target, permission, identity and content
  checks. Keep an explicit copy fallback; never execute commands automatically.

## Verification and evidence

- Verify links, publication boundaries and `git diff --check` for documentation.
- Use full Xcode with the macOS 26 SDK or later. `DEVELOPER_DIR` may select a
  specific installation. Command Line Tools alone cannot run native tests.
- Run `./scripts/verify.sh unit`, `integration`, or `ui` for complete XCTest
  targets; append a class name for focused runs. Use `release-build`,
  `warnings-build`, or `all` for broader checks. The shared project/scheme is `Keeptide`; results stay in `.local/`.
- Run `python3 -m unittest discover -s scripts/tests -v` when changing the
  verification script. These checks do not substitute for native XCTest.
- Test behavior and failure boundaries. For meaningful changes, run focused
  tests first, then the relevant integration/build checks. Do not add tests that
  merely mirror formatting or implementation details.
- Storage changes need real temporary-disk tests and reopen/migration coverage.
  Search changes need literal input, short Chinese queries, cancellation and
  stale-result checks. Preserve stable synthetic migration fixtures.
- Native UI, text composition, focus, permissions and cross-application actions
  require signed native-app evidence. A web mockup cannot establish these claims.
- Cloud recovery requires a real isolated-account round trip. Mocks establish
  application rules, not cloud-service behavior. Performance claims require a
  recorded Release build, dataset and machine.
- Report what changed, why, what actually ran, and remaining gaps. Keep detailed
  logs and captures local; public summaries must be sanitized and truthful.

## Review and delivery

- Each PR must build and validate on its already-merged dependencies. Do not
  count passing tests on a future dependency as integration evidence.
- Flag content loss, wrong-target insertion, stale content execution, broken
  IME/focus, private-data publication and cross-account writes as release blockers.
- Treat signing, notarization and production cloud-schema deployment as explicit
  release operations, separate from ordinary builds and merges.
- GitHub publication must be within the user's requested scope. Recheck the
  destination account, repository and staged content before sending it.
- Keep public milestones at capability level. Track detailed progress, failures
  and implementation decisions in the local Chinese plan.
