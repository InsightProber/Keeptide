# Contributing to Keeptide

Thank you for taking an interest in Keeptide. The project is in early native
development. A menu-bar application, quick-access panel, library shell, and
verification infrastructure are present. Local persistence and content
validation are implemented, together with local recording, a recent-clips list,
original-format copying, a rebuildable local search index, and a quick-access
panel that shows clips as a band of cards, searches, previews content, copies,
and pastes into the app it was opened from. The reusable snippet library,
collections, local lifecycle controls, settings, and local archive export are
implemented foundations. Cloud integration and release qualification remain
planned work.

## Before making a change

Read the [feature scope](docs/features.md), [architecture](docs/architecture.md)
and [roadmap](docs/roadmap.md). The [shared project instructions](AGENTS.md)
describe the engineering and review expectations for human and agent contributors.

Keep contributions focused on a specific problem. Describe the resulting
behavior, the validation actually performed, and any limitations. Do not label
planned functionality as available or invent build commands for missing targets.

## Documentation

Public documentation is written in English. It covers the product, overall
architecture, feature scope and capability milestones. Shared contributor and
agent instructions are also public.

Detailed development plans, module designs, research, prototypes and raw QA
evidence belong under `.local/` and are ignored by Git. Their prose is written in
Chinese. A fresh clone does not require those local files to read or review the
public project direction. Public documents must not link to unpublished files.

Before committing, inspect the staged paths and diff. Confirm that
`git ls-files -- .local` produces no output. Do not force-add local material or
include it indirectly in screenshots, issue bodies or CI artifacts.

## Verification

Use full Xcode with the macOS 26 SDK or later, and open `Keeptide.xcodeproj` with
the shared `Keeptide` scheme. Set `DEVELOPER_DIR` when selecting an installation.
The verification entry point provides these commands:

```sh
./scripts/verify.sh unit AppLaunchTests
./scripts/verify.sh integration ContentRepositoryTests
./scripts/verify.sh ui NativeShellUITests
./scripts/verify.sh release-build
./scripts/verify.sh warnings-build
./scripts/verify.sh analyze
./scripts/verify.sh all
./scripts/benchmark.sh
./scripts/benchmark.sh --million
```

`unit` and `integration` run `KeeptideTests`; `ui` runs `KeeptideUITests`.
An optional class name narrows the selection. CI runs complete targets, and the
script rejects empty, entirely skipped, or unreadable results. Test builds use
local ad-hoc signing without developer credentials. CI uses the same script. Developer ID signing, notarization, and
cloud provisioning are separate release operations. The build embeds a short-lived
clipboard reader with inherited sandbox entitlements. Its signing step deliberately
uses the checked-in helper entitlement set; XCTest's extra test-host entitlements
must not be propagated to that helper.

`analyze` runs Xcode's static analyzer without signing. The default benchmark
runs a fixed 10,000-item search oracle and a 100,000-item SearchService
measurement in Release configuration. `--million` explicitly opts into the
one-million-item stress run and is not part of ordinary verification. The
benchmark measures service build/query behavior and gates only SearchService's
first batch; it does not establish UI presentation latency or responsiveness.
It requires a clean worktree so the recorded Git SHA identifies the measured
code. Detailed evidence is written only below the ignored `.local/benchmarks/`
directory; do not commit those logs, result bundles, or reports.

For verification-script changes, also run
`python3 -m unittest discover -s scripts/tests -v`. Documentation changes need
accurate status, valid links, consistent terminology, and `git diff --check`.
Logs and result bundles belong under the ignored `.local/` directory.

Passing automated checks is necessary but is not a release declaration. There
is no completed Developer ID signing, notarization, production cloud recovery,
or sustained-use acceptance claim in this repository. Record those operations
only after they have actually run against the exact candidate SHA.

Changes to native UI, input methods, permissions or destination selection need
real macOS validation. CI and direct Swift compilation do not establish real
input-method, multi-display, permission, or release-signing behavior. Changes to
cloud recovery need isolated real-service
evidence in addition to deterministic application tests. Use synthetic test data;
never include personal content, credentials or signing material in submissions.

## Icon artwork

The application and installer volume share the same Keeptide icon. The menu bar
uses a separate monochrome vector template so macOS can adapt its contrast.
The app icon is maintained in `Keeptide/Resources/AppIcon.icon` with editable SVG
layers. Open it in Icon Composer to edit materials and appearances. After changing
it, export the macOS Default appearance as a 1024-pixel PNG and run
`swift scripts/export_installer_artwork.swift <export.png>` from the repository
root. Commit the updated installer artwork and source fingerprints together.
Packaging checks those fingerprints and creates a full-resolution installer icon;
it does not depend on the build machine's icon cache or desktop appearance.
Review small sizes and Default, Dark, and Mono appearances; keep compatibility
with the CI Xcode version.

## Coding agents

Codex reads the root `AGENTS.md`. Claude Code reads `CLAUDE.md`, which imports the
same file. Make shared policy changes in `AGENTS.md` so the two tools stay aligned.
Local agent state and personal configuration are not part of the repository.

## License

The project uses the [Apache License 2.0](LICENSE). Contributions intentionally
submitted for inclusion are provided under that license unless explicitly stated
otherwise. Preserve applicable copyright notices and third-party attribution.
