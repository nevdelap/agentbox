# Task 17 — Concurrent interactive agent access

Status: Proposed

## Problem

The project lock currently remains held through the entire `docker exec` that
implements `ab bash`, `ab codex`, `ab claude`, and `ab exec`. This correctly
serializes lifecycle mutation, but it also makes one long-lived interactive
agent block every other agent for the same project. After the 30-second lock
timeout, the second agent receives `project busy` even when the container is
healthy and ready.

This is a regression in supported functionality. Multiple agents must be able
to enter the same ready agentbox concurrently.

## Goal

Restore concurrent interactive access while retaining exclusive coordination
for lifecycle and policy mutations.

## Scope

- Separate the exclusive lifecycle-mutation lock from the interactive command
  execution path.
- Keep `start`, `start --apply`, `build`, `rebuild`, `stop`, and `destroy`
  mutually exclusive for one canonical project/machine identity.
- Permit multiple concurrent `ab bash`, `ab codex`, `ab claude`, and
  `ab exec` sessions when the target container is ready.
- Treat non-mutating `status`, `logs`, and plain `config` as read-only
  operations; they must not wait behind an interactive session for the full
  lock timeout. `config init` is not read-only: it writes configuration files
  and must use the exclusive mutation boundary.
- If an interactive command must auto-start or explicitly recover a container,
  hold the exclusive lock only through the required preflight and lifecycle
  mutation. Release it before the resulting `docker exec` session begins.
- After acquiring the exclusive lock, re-inspect policy, container, and
  operation state. If another process already completed the required mutation,
  skip the duplicate mutation and hand off from the newly validated state.
- Preserve the existing operation-record, readiness, permission, retry, and
  report contracts. A normal interactive session must not create a second
  lifecycle operation or rewrite durable lifecycle state after handoff.
- Release every acquired descriptor on success, refusal, failure, signal, and
  child-process exit. A failed interactive command must not leave later agents
  permanently blocked.

## Lock boundary

The implementation must document and test this sequence:

1. Resolve policy and inspect the current operation state.
2. Acquire the exclusive lock only if lifecycle mutation or reconciliation is
   required.
3. Re-inspect policy, container, and operation state while holding the lock;
   recompute whether mutation is still required.
4. Complete only the still-required lifecycle operation and publish its
   terminal state.
5. Release the exclusive lock before invoking the long-lived `docker exec`.
6. Run the interactive command without holding the lifecycle lock.

If another process is already performing a lifecycle mutation, an interactive
command may wait for that bounded transition or refuse according to the
existing policy decision. It must not mistake a healthy interactive session
for an in-progress lifecycle operation.

An explicit lifecycle command may still interrupt existing interactive
sessions when its accepted semantics require stopping or recreating the
container. That mutation must remain serialized and must leave a valid
operation record and report.

## Tests

Add deterministic source-based regressions using the existing Docker/helper
seams. The tests must prove:

- Two simultaneous ready-container `ab bash`/`ab exec` invocations overlap and
  neither returns `project busy`.
- Convenience launchers for Codex and Claude use the same non-exclusive
  handoff after any required auto-start.
- Two lifecycle mutations for one project remain serialized; only one writer
  can change the container, volumes, policy, or operation record at a time.
- Two concurrent auto-starting interactive commands perform at most one
  lifecycle mutation, re-inspect after lock acquisition, then both enter the
  ready container.
- `status`, `logs`, and `config` remain usable while an interactive session is
  open and do not acquire the long-lived execution lock. `config init` remains
  an exclusive configuration mutation and cannot race another writer.
- A refused, failed, interrupted, or signalled command releases its lock and
  allows a later lifecycle or interactive command to proceed.
- Reports and exit statuses remain unchanged for ready, refused, failed, and
  recovery paths.

Use a barrier or equivalent deterministic fake command rather than sleeping
for an assumed scheduling interval. Do not start real agents or Docker
daemons for this regression suite.

## Non-goals

- Do not add a second durable lifecycle record, lock, supervisor, event log, or
  public report API.
- Do not weaken serialization of container recreation, policy application,
  volume changes, network mutation, or operation-record writes.
- Do not change accepted command names, exit categories, report fields,
  readiness semantics, or retry commands except where required to remove the
  accidental interactive-session exclusion.
- Do not solve unrelated stale-record, Docker readiness, or credential-mount
  behavior.

## Acceptance criteria

- Multiple interactive agents can use one ready project concurrently for an
  unbounded session duration without a false `project busy` refusal.
- The exclusive lock is not held across any long-lived `docker exec`.
- Every mutation path re-inspects state after acquiring the exclusive lock and
  avoids duplicate work when a concurrent mutation already completed.
- Plain `config` is read-only, while `config init` is explicitly covered by
  the exclusive mutation lock.
- Lifecycle mutations remain serialized and all existing no-side-effect
  refusal guarantees remain true.
- The focused concurrency regressions and the complete repository gate pass:
  `just qformat`, `just qlint`, `just qtest`, and `just qcheck`.
- The implementation handoff identifies the exact lock acquisition and
  release boundaries and includes evidence for every criterion above.
