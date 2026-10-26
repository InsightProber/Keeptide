# Contributing to Keeptide

Thank you for taking an interest in Keeptide. The project is currently in its
documentation and repository-foundation stage. A buildable native application and
its verification scripts will arrive with the implementation milestones.

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

Documentation changes need accurate status, valid links, consistent terminology,
and a clean `git diff --check`. Native code changes will require the appropriate
build, focused tests and integration checks once those targets exist.

Changes to native UI, input methods, permissions or destination selection need
real macOS validation. Changes to cloud recovery need isolated real-service
evidence in addition to deterministic application tests. Use synthetic test data;
never include personal content, credentials or signing material in submissions.

## Coding agents

Codex reads the root `AGENTS.md`. Claude Code reads `CLAUDE.md`, which imports the
same file. Make shared policy changes in `AGENTS.md` so the two tools stay aligned.
Local agent state and personal configuration are not part of the repository.

## License

The project uses the [Apache License 2.0](LICENSE). Contributions intentionally
submitted for inclusion are provided under that license unless explicitly stated
otherwise. Preserve applicable copyright notices and third-party attribution.
