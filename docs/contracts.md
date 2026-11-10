# Ownership and evidence

`Identity` contains a PID, identifier scope and optional native generation
evidence. Matching available evidence is not control authority. `Observation`
keeps presence, termination and execution state separate. Missing fields remain
unknown; queries never invent a generation token.

`Handle` owns one authority view. `Handle::Borrowed` cannot close or transfer it.
Duplicate handles have independent local lifetimes. Admitted control operations
retain their authority while a pending receipt exists. Closing refuses later
work; cleanup that still depends on admitted work returns `Retryable`. Explicit
cleanup retry does not replay an uncertain native close or a control request.

## Darwin checked control

`Handle.open` keeps observation-only requests on the sampled PID route. A
control or checked-binding request on Darwin selects `Platform::Darwin.open`.
`Binding::Checked` means the native action validates its target identity while
acting. An explicit retained or delegated binding requirement does not match it.
`Platform::Darwin.available?` checks the runtime symbol, not target permission.

Acquisition owns a task-name Mach send right and reads its audit token before
validating the expected identity. `Identity::Generation` carries the unsigned
PID version in the `darwin.audit.pidversion` domain. This is local evidence;
the shard does not establish a host or boot identifier. Token bytes and Mach
names stay internal. Duplicate handles retain independent references to the
same Mach right, without reopening a PID. A changed caller PID refuses native
I/O; inherited handles and raw fork integration are unqualified. Unattempted
release can be retried in the owner context; failed native release is recorded
as uncertain. Incomplete acquisition cleanup retains its closed owner through
`Handle::Acquisition::Failed`.

Observation reads the owned reference and verifies the token's PID/version.
Failure or conflicting evidence leaves presence and termination unknown.
The profile has no exit-wait or child-status source. Token-bound signaling
uses the caller's current kernel permissions; the token is identity evidence.
Stop sends `SIGTERM`, kill sends `SIGKILL`, and suspend/resume send `SIGSTOP`
and `SIGCONT`. Those last two have POSIX job-control semantics. A signal receipt
reports the native call result; it does not verify a later process state.
Positive native errno values remain attempted failures. Signal zero is invalid
and is never used as a permission probe. There is no PID-only action fallback.

## Child ownership

Control dispositions carry their own payloads: `Refused`, `Satisfied`,
`Report::Success`, `Report::Failure`, `Report::Partial` and `Delivery::Unknown`.
Postcondition evidence is independent. A reported failure does not establish
rollback, and observing a later exit does not establish its cause. A control
pending ticket observes one request; closing the ticket does not resend or
cancel it.

`Child` has one status source. The source caches one terminal status or collection
failure and shares it across waiters. Timeout and cancellation affect an individual
wait. Status waiting continues after child close. Output EOF and target exit are
separate; a descendant may keep output open after the target exits.

The Unix backend launches a native helper with an authenticated private socket.
The helper is written in Crystal, with a custom `main` and no managed runtime
startup. An explicit build audits both unoptimized and release LLVM, following
calls and callbacks and rejecting reachable mutable globals before
installing the executable. This is a compiler-artifact check, not a proof of all
native ABI or operating-system behavior.
The helper forks and reaps the logical target and serializes signaling with
reaping. It never signals after target reaping. The Crystal runtime reaps the
helper; its cached numeric-PID status is ignored for target attribution. Stdio
is separate from the socket protocol. Parent pipe endpoints are atomically
duplicated before their original helper-process wrappers are released.

`Spawn::Registration` transfers ownership once. Invalid handoffs retain an owning
pending registration when cleanup cannot be established. A pending launch transfers
its child once. Explicit abort requests cleanup; a lost acknowledgment remains
uncertain rather than becoming a pre-launch rejection. No automatic creation
retry or numeric-PID fallback is used.

The initial native profile uses Crystal fibers with the runtime's normal
shared descriptor table. Control views reject a different execution thread.
Every helper frame includes the session token so unrelated protocol traffic
cannot become a target's status or control request. Private descriptor tables,
foreign raw-thread calls and changed authority contexts remain unqualified.

Native startup/protocol loss can leave an unresolved launch ticket; the helper
continues reaping its target even if its peer disappears. Lost control authority
does not justify reopening the target by PID. Recovery/reconnection and external
manager transfer are not implemented in this release. Keep the pending owner and
its diagnostics; do not report cleanup that could not be confirmed.

Group shutdown closes local spawn admission and accounts for admitted
launches before final drain. A native controller must declare binding, membership,
escape and owner-death guarantees. A PID list or process group is not universal
containment. The core does not manufacture a native group backend.

Cleanup records may carry a `Control::Release::Participant` for a retained resource.
That participant can retry independently while uncertain records remain intact;
an uncertain native close is never replayed. Providers returning mixed cleanup
outcomes must attach participants to the separately retryable resources. Failed
duplicate acquisition exposes its closed cleanup owner through
`Handle::Acquisition::Failed` when native release remains incomplete.

Streams accept native descriptors and explicit inherit/close/pipe/capture policies.
Arbitrary caller-IO copy callbacks are not implemented. Capture has one coordinator
per output. An expired completion returns current target/copy evidence; it does
not claim that pending copies settled. All normal waits use monotonic deadlines.

`Clock.now` supplies every observation timestamp and deadline. A compile-time
check selects `Time.instant` and `Clock::Instant = Time::Instant` where available;
older compilers use `Time.monotonic` and `Clock::Instant = Time::Span`. Durations
remain `Time::Span` on both paths. These are monotonic readings, not wall-clock
timestamps. The stdlib clock determines whether system sleep counts toward a
deadline: before Crystal 1.19 it is excluded on macOS and Linux; since 1.19 it
is included. The shard does not change that platform/compiler behavior.
See the [Crystal 1.19 clock changes](https://crystal-lang.org/2026/01/15/1.19.0-released/#adjust-monotonic-clocks).

Protocol sequence values are unsigned 64-bit decimal integers. Malformed or
overflowing numeric fields close the control channel without delivering control;
the helper continues collecting its target. A reported target exit 127 remains
distinct from an exec/setup error reported through the close-on-exec error pipe.
