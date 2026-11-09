# Roadmap

Keeptide is in early native development. The milestones below
describe capability outcomes, not released features or delivery dates.

| Milestone | Outcome | Completion evidence | Status |
| --- | --- | --- | --- |
| M0 — Native and storage foundation | Native application shell, reliable content persistence, and an early iCloud feasibility check | Real macOS interaction, disk reopen tests, and an isolated cloud recovery round trip | In progress |
| M1 — Local clipboard workflow | Capture, search, preview basics, copying and validated insertion | End-to-end operation in real destination applications, including input-method and permission behavior | In progress |
| M2 — Reusable library | Editable snippets, drafts, collections, richer previews and retention controls | Native editing, restart recovery, content identity and safe lifecycle validation | In progress |
| M3 — Recovery and user control | Full background cloud integration, account isolation, settings and exports | Clean-install recovery, account transition checks and independently verified exports | In progress; local controls implemented, cloud validation pending |
| M4 — First release | A signed, accessible and responsive application suitable for daily use | Integrated regression checks, representative large libraries, supported-OS validation and sustained use | Planned |

## Current foundation

The repository currently contains a native menu-bar application, quick access
with lists for snippets and collections, clipboard recording, validated local
persistence, a rebuildable search index, editable text and Markdown snippets,
collections, favorites, library list counts and filters, typed previews, local
retention and Recently Deleted, settings, and independently verifiable local
archive export. Deterministic native tests exercise these application and
storage boundaries with synthetic temporary data.

Search benchmark tooling records a fixed synthetic dataset, seed, configuration,
Git SHA, toolchain, and machine. Its performance gate applies to the first batch
from SearchService in a Release test build. It is not evidence of quick-access
rendering or end-to-end UI latency.

Release automation builds and verifies an Apple silicon DMG, checksum, and build
metadata for published version tags. The current packages use ad-hoc signatures;
Developer ID signing and notarization remain pending. PR and manual workflow runs
produce test artifacts without publishing releases.

## Remaining first-release gates

- Complete signed manual validation for keyboard focus, input methods,
  Accessibility permission states, multi-display/Spaces behavior, and real
  destination applications.
- Run representative Release benchmarks and sustained-use observation on the
  exact candidate SHA; the presence of benchmark tooling is not a passing run.
- Complete Developer ID signing, notarization, supported-macOS checks, and the
  downloaded-package installation and upgrade checks.
- Validate iCloud account isolation, background persistence, and clean-install
  recovery with a real provisioned container before enabling or claiming cloud
  support.
- Finish the documented disk-capacity, migration-failure, accessibility, and
  long-duration acceptance matrix. Automated tests and mocks do not substitute
  for these system-level checks.

## Release principles

- Local workflow development can proceed while cloud feasibility awaits the
  required developer account and signing setup. Cloud recovery remains an
  explicit validation gate before shipping iCloud support.
- Validate native interaction and cloud feasibility early.
- Verify UI quality with the native application throughout development.
- Keep the main branch buildable once the application project exists.
- Measure performance on a recorded Release build and representative data.
- Treat data loss, incorrect destination actions and account isolation failures
  as release blockers.
- Report unverified behavior clearly; prototypes and simulated services cannot
  establish system-level behavior.

## After the first release

The next phase may explore semantic retrieval and contextual content suggestions.
These capabilities should build on the existing content and search boundaries,
with explicit user control and separately validated privacy and performance.
No model provider or delivery schedule is committed at this stage.
