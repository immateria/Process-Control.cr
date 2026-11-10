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
