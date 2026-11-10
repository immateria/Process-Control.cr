# Behavior-lab inputs

The implementation is original code. Research source and handback files remain
outside the repository. No experimental library source was copied into this
shard.

Two process-lab inputs were inspected:

- `immateria/native-test` at `0a4f7a89d7c90449748376012ff410863eb51114`, with
  the earlier workspace audit/reconciliation and retained Actions receipts.
- The supplied `crystal-native-process-probes-0006-r7` bundle: checkpoint 0006,
  experimental handle/supervision version 0.6.0, revision-7 probe sources and
  the included macOS handback.

The r7 bundle's prose says native runtime pending. Its included macOS result
stream contains 370 passing behavioral cases and four failing zombie-related
cases, plus environment/summary records. The SDK stream contains 40 passing
behavioral cases and its summary. These are supplied historical receipts, not
runs of this shard. All four failures report that numeric-PID presence was false;
that alone does not establish that the fixture still held an unreaped zombie.

Applied lessons include explicit target SIGPIPE reset independent of Crystal's
ignored default; repeated finite-wait regression cases; presence versus termination
separation; no libproc absence-to-death inference; no raw-thread `Channel` bridge;
separate child status/output completion; and one target reaper.

Windows lessons remain qualification requirements for that future backend:
one registered native wait per finite wait, callback/unregistration lifetime,
token and Job context, explicit inherited-HANDLE allowlists, raw unsigned exit
values, hidden drive environment entries and unresolved build-17763 CPU-limit
enforcement. A round-tripped Job limit is not proof of enforcement.

The C-free replacement keeps the same separate target owner. A custom-main
Crystal probe launched and collected a native child on macOS/Linux ARM64 with
1.21.0 and 1.22.2. Full-helper review then exposed why release-only auditing is
insufficient: the optimizer can fold uninitialized runtime state to zero. Both
unoptimized and release artifacts are now checked, with mutable global state
refused. The helper constructs native signal sentinels directly.

Protocol regressions retain unsigned sequence boundaries and target exit 127,
and reject numeric overflow and embedded NUL without delivering control. A
peer-read-shutdown fixture checks that SIGPIPE cannot terminate the target owner
before it collects the child. These are tests of this shard's helper, separate
from the historical behavior-lab receipts above.

## Consolidated process surveys

The supplied `process-surveys-consolidation-z6lcfo4t` directory was checked on
2026-11-10. Its `macOS-integrated.md` and `Windows-integrated.md` are the final
surveys; the same-named survey files inside that directory are backups. The
final files match the installed-manifest hashes. These are static research,
separate from the behavior-lab receipts and this shard's native suites.

The strongest new lead is Darwin's `proc_signal_with_audittoken`. Santa uses it
for kill, and Apple's kernel source binds the action to the token's incarnation.
An independent owned-child experiment on macOS 15.4.1 ARM64 rejected a wrong
pidversion, delivered SIGTERM through the correct token, and rejected the token
after collection. Signal zero is invalid on this interface, and errors are
returned directly as positive errno values. The experiment is not a production
Crystal backend or full native qualification. Santa's PID-only suspend and
check-then-PID resume paths do not establish the same identity guarantee.

Other useful transfers fit the existing optional homes: Windows handles/launch
attributes/Jobs; separate readiness and service ownership; cancellable serialized
action budgets; generation-aware snapshots; and explicit event-loss evidence.
The workspace review `docs/reviews/process-control-surveys-2026-11-10.md` maps
these findings, records source revisions and the probe, and names the binding
model question to resolve before implementing Darwin token control. Existing
numeric-PID control remains refused.

The follow-up implements the checked-binding profile through the macOS libproc
symbol. It keeps a task-name reference for observation and checks the acquired
token during each signal. The native suite tests delivery, stale-token rejection
and independent duplicate cleanup, with child status still collected through
the original helper. The earlier survey and FFI probe remain distinct evidence.
