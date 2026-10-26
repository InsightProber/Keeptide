# Roadmap

Keeptide is in the design and repository-foundation stage. The milestones below
describe capability outcomes, not released features or delivery dates.

| Milestone | Outcome | Completion evidence | Status |
| --- | --- | --- | --- |
| M0 — Native and storage foundation | Native application shell, reliable content persistence, and an early iCloud feasibility check | Real macOS interaction, disk reopen tests, and an isolated cloud recovery round trip | Planned |
| M1 — Local clipboard workflow | Capture, search, preview basics, copying and validated insertion | End-to-end operation in real destination applications, including input-method and permission behavior | Planned |
| M2 — Reusable library | Editable snippets, drafts, collections, richer previews and retention controls | Native editing, restart recovery, content identity and safe lifecycle validation | Planned |
| M3 — Recovery and user control | Full background cloud integration, account isolation, settings and exports | Clean-install recovery, account transition checks and independently verified exports | Planned |
| M4 — First release | A signed, accessible and responsive application suitable for daily use | Integrated regression checks, representative large libraries, supported-OS validation and sustained use | Planned |

## Release principles

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
