# Agentbox release checklist

This checklist records Task 14 documentation and release-readiness evidence. It
does not create a release tag or publish an artifact.

## Repository gates

- [x] `just qformat` — formatting completed without changing the submitted tree.
- [x] `just qlint` — Docker, Markdown, shell, YAML, and commit-description lint
  passed.
- [x] `just qtest` — Nix parsing and source-based shell tests passed.
- [x] `just qcheck` — the complete gate passed.
- [x] Internal links and every documented repository path were checked.

The quiet recipes print only their result. If one fails, inspect the full
`check.log` before making a correction; do not treat a truncated tail as the
complete diagnostic.

## Runtime evidence

The latest authorized Task 13 run is recorded at
`/tmp/agentbox-task13.rSsvdx/result.toml` and is not a release input. Its status
was `pass`, with all rows `P13-01` through `P13-08` passing.

| Evidence                           | Status | Detail                                                       |
| ---------------------------------- | ------ | ------------------------------------------------------------ |
| Docker client/server               | Passed | 29.7.2 / 29.7.2                                              |
| Sysbox runtime                     | Passed | Sysbox 0.7.0 and `sysbox-runc` registered                    |
| Nested hello-world                 | Passed | Docker API and nested image execution succeeded              |
| Git/jj/`gh` and policy transitions | Passed | Covered by P13-02 through P13-05                             |
| Operation reports and retry paths  | Passed | Covered by P13-06 through P13-08                             |
| Network accounting                 | Passed | Inventory verified                                           |
| Cleanup                            | Passed | Cleanup eligible and completed; owned resources were handled |

Runtime validation is environment-dependent. A host without Docker or
`sysbox-runc` is **blocked**, not a product pass; a test deliberately omitted by
its prerequisites is **not applicable**, not a pass. The recorded run above was
neither blocked nor not applicable.

## Safety and release review

- [x] Credentials are explicit mounts; policy files contain no credentials and
  are mounted read-only.
- [x] Failed operations retain diagnostics and named Docker/jj volumes.
- [x] Only explicit `ab start --apply` or `ab rebuild` recovery may mutate
  failed state; `ab destroy` is the deliberate volume-destroying command.
- [x] Review-owned `review_docs/` and review-named `design_docs/` files were not
  edited or added by Task 14.
- [x] No release tag or published artifact has been created.

## References

- [`README.md`](./README.md) — user interface, policy, safety, and test usage.
- [`bin/ab`](./bin/ab) — command help and report vocabulary.
- [`tests/run.sh`](./tests/run.sh) — source-based regression suite.
- [`tests/runtime_matrix.sh`](./tests/runtime_matrix.sh) — supported-runtime
  evidence.
- `design_docs/` — completed design and implementation-plan documents were
  retired after Tasks 1–16 were merged; the accepted implementation and tests
  are the release evidence.

## Unresolved blockers

Before a public release, the repository gates above must be checked on the final
tree and CI must pass. This Task 14 change does not itself publish a release or
create a tag.
