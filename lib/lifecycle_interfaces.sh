#!/usr/bin/env bash
# Internal lifecycle interfaces for bin/ab.
#
# These functions are intentionally small adapters. They are the only production-facing
# boundary for the Task 7 record codec, the Task 8 decision/projection adapter, and the Task 9
# command report renderer. The implementation functions they call remain in bin/ab so the
# launcher keeps one lifecycle vocabulary and one state store.
#
# Interface contract:
#   lifecycle_record_read
#     Inputs: current project identity and operation_record_path globals.
#     Output: return status; decoded durable fields and the projection are process state.
#     Side effects: reads one scoped host record; no Docker, network, update, or lifecycle work.
#   lifecycle_record_write
#     Inputs: current operation producer fields and operation_record_path globals.
#     Output: return status; durable record is replaced atomically on success.
#     Side effects: creates/chmods one scoped record directory and atomically renames one
#     temporary record; no Docker, network, update, or policy decision.
#   lifecycle_projection_build
#     Inputs: current policy decision and operation producer fields.
#     Output: return status; one operation_state_* projection in process state.
#     Side effects: process-memory assignment only; no record, Docker, network, update, or
#     lifecycle mutation.
#   lifecycle_report_render
#     Inputs: optional result, reason, and exit-status override plus the current projection.
#     Output: report text on stdout when enabled; report globals and return status.
#     Side effects: projection refresh and stdout output only; no record, Docker, network,
#     update, or lifecycle mutation.
#
# shellcheck disable=SC2154 # globals are owned and initialized by bin/ab before this is sourced

lifecycle_record_read() {
  operation_record_load "$@"
}

lifecycle_record_write() {
  operation_record_write "$@"
}

lifecycle_projection_build() {
  operation_state_publish "$@"
}

lifecycle_report_render() {
  command_report_emit "$@"
}
