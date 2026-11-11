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
control, exit-wait or checked-binding request on Darwin selects
`Platform::Darwin.open`.
`Binding::Checked` means the native action validates its target identity while
acting. An explicit retained or delegated binding requirement does not match it.
`Platform::Darwin.available?` checks the kernel-release guard for audit-token
signaling, not target permission. The ARM64 and x86-64 backend enters BSD syscalls
and Mach traps directly. Its task-message guard requires Darwin 22 (macOS 13)
or later; its audit-token signal guard requires Darwin 24 (macOS 15) or later.
These are source-derived availability floors, with native scope recorded in
[support](support.md).

Acquisition owns a task-name Mach send right and reads its audit token before
validating the expected identity. `Identity::Generation` carries the unsigned
PID version in the `darwin.audit.pidversion` domain. This is local evidence;
the shard does not establish a host or boot identifier. Token bytes and Mach
names stay internal. Each token read sends a `task_info` MIG request for
`TASK_AUDIT_TOKEN` through `mach_msg2`. It owns a dedicated receive right for the
reply, releases that right after the exchange, and validates the reply layout
before reading its payload. Duplicate handles retain independent references to the
same Mach right, without reopening a PID. A changed caller PID refuses native
I/O; inherited handles and raw fork integration are unqualified. Unattempted
release can be retried in the owner context; failed native release is recorded
as uncertain. Incomplete acquisition cleanup retains its closed owner through
`Handle::Acquisition::Failed`.

Observation reads the owned reference and verifies the token's PID/version.
Failure or conflicting evidence leaves presence and termination unknown. The
sampled Darwin route can also report a present, terminated zombie when
the kernel process-info query returns a matching zombie record. Process roster,
record and PID-version queries use the same direct syscall entry.

A request containing `wait.exit` opens a private kqueue and registers
`EVFILT_PROC/NOTE_EXIT` for the captured PID. A fresh PID-version query after
registration must agree with the captured Mach token. An unsuccessful
registration, missing generation or mismatch fails acquisition. In particular,
`ESRCH` at registration supplies no exit evidence for the acquired identity.
Duplicate views share one event reader and cached terminal observation. The
last close releases the queue. Finite waits and cancellation use the portable
monotonic wait loop, and an interrupted read remains eligible for another
sample. The event proves termination. Presence and execution state at that
point remain unknown, and the event has no child status.

An explicit wait-only request acquires observation and wait capabilities.
Token-bound signaling
uses the caller's current kernel permissions; the token is identity evidence.
Stop sends `SIGTERM`, kill sends `SIGKILL`, and suspend/resume send `SIGSTOP`
and `SIGCONT`. Those last two have POSIX job-control semantics. A signal receipt
reports the native call result; it does not verify a later process state.
Positive native errno values remain attempted failures. Signal zero is invalid
and is never used as a permission probe. There is no PID-only action fallback.

## Linux retained control

On Linux ARM64 and x86-64, an explicit retained binding, exit wait, or control
request to `Handle.open` selects the pidfd profile. The default observation
request keeps the sampled PID route. `Platform::Linux.open` explicitly selects
the retained profile. Its public identity contains the local PID without a
generation token. An expected PID and scope can match, while a generation
requirement is unverifiable.

Acquisition and duplication own close-on-exec descriptors. A zero-time pidfd
poll supplies termination evidence for the retained process. A hangup also
establishes that the retained process has been reaped. The wait observes exit
without collecting a status or reaping the process. A separate child owner
can still collect its status. [Linux pidfd documentation](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)

Control sends the requested POSIX signal through the retained descriptor. Stop
sends SIGTERM, kill sends SIGKILL, and suspend/resume use SIGSTOP and SIGCONT.
Native errno is preserved after attempted delivery. A successful signal receipt
only records acceptance by the kernel. Signal zero and non-POSIX signal domains
are refused. A changed process context refuses native use, and an uncertain close
is recorded without replay. [Linux signal delivery documentation](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)

## Linux delegated cgroups

`Platform::Linux::Cgroup.open(path, request)` retains an existing cgroup v2
domain selected and owned by the caller. Use a dedicated trusted subtree. A
local group close releases its descriptors. The caller owns the directory and
its removal, and descendants follow the kernel's cgroup inheritance rules.
Privileged migration can change membership. This profile supplies no owner-death
action or escape prevention beyond the kernel's configured permissions.

The delegated profile reads recursive population and freezer state from
`cgroup.events`. Where writable, `cgroup.freeze` supports group suspend and
resume, and `cgroup.kill` supports recursive SIGKILL. The aggregate control
effect reports the write result. Use `Group#observe` for freezer state and
`Group#wait_empty` for drain evidence. A requested freezer change may take time
or remain constrained by an ancestor. [Linux cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)

`group.birth` requires the cgroup-aware clone3 ABI and a writable
`cgroup.procs` descriptor. The Unix launcher keeps the directory owner admitted
through launch and the helper checks the directory device and inode before
`clone3(CLONE_INTO_CGROUP)`. The kernel decides placement permission at each
launch. Acquisition refuses a `group.attach` requirement because moving an
existing process via `cgroup.procs` uses a numeric PID. Group kill disables
future birth requests when its native write is attempted. Use shutdown to
close admission and settle in-flight launches before kill and drain.
[Linux clone3 documentation](https://man7.org/linux/man-pages/man2/clone3.2.html)

The group binds its native launcher to the admitted plan. The freezer refuses
to suspend a group with an admitted launch, and birth is unavailable while
freeze is requested or observed. Use a dedicated subtree with thawed ancestors
during startup. Concurrent freezer changes by another controller or an ancestor
are outside this profile and can leave startup awaiting acknowledgment.

## Child ownership

Unix commands can request `Spawn::Session` and finite `Resource::Limit`
settings. Session creation makes the logical target a new session and
process-group leader. The helper remains its parent and collector. Limits
are CPU seconds, bytes per file, bytes per core file, or open descriptor
count. Soft and hard bounds are applied and read back in the target before
exec. Setup, creation and exec failures carry separate stages.

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
reaping. It never signals after target reaping. On Darwin its fork, wait, signal,
descriptor, setup and exec operations use direct kernel traps. On Linux those
operations use C-ABI system interfaces. The Darwin helper's unoptimized and
release LLVM permit no external function imports and only the exact approved
trap and memory-barrier assembly. The dead-stripped release executable must
also have empty `nm -u` output. Apple's linker requires a libSystem loader entry
even for this executable with no undefined imports.

The managed Darwin parent creates the helper with a direct spawn syscall and
private attribute/action layouts, gated to Darwin 24. The trusted unmanaged
helper runs immediately and waits for the exact authenticated `START` frame
before creating the logical target. Control-channel EOF before that frame ends
the helper without creating a target. After target creation the helper remains
its parent and collector even if the peer disappears. That layout and startup
cleanup require their own qualification; the
[rewrite record](support.md#direct-darwin-rewrite-on-2026-11-10) tracks the open
checks. Linux creates the helper through Crystal's process API. The runtime
still reaps the helper for bookkeeping; its numeric-PID status is ignored for
target attribution. Stdio is separate from the socket protocol. Parent pipe
endpoints are atomically duplicated before their original helper wrappers are
released.

The managed Crystal runtime, scheduler, synchronization and ordinary file,
socket and stream I/O retain their platform-library dependencies. The direct
Darwin process entry calls and the unmanaged helper's empty import table do not
make the managed application free of C-library calls.

`Spawn::Registration` transfers ownership once. Invalid handoffs retain an owning
pending registration when cleanup cannot be established. A pending launch transfers
its child once. Explicit abort requests cleanup; a lost acknowledgment remains
uncertain rather than becoming a pre-launch rejection. No automatic creation
retry or numeric-PID fallback is used.

Settlement callbacks run after the ticket records its terminal result and
outside the ticket's lock. Every queued subscriber is invoked once. Exceptions
become callback-stage diagnostics in `callback_failures`, whose accessor returns
a copy. Subscribers added after settlement use the same notification rules.
Callback failures leave the terminal result available and allow the remaining
subscribers to release their admission and authority leases. This applies to
launch tickets, abort settlement and pending control receipts.
Another waiter may resolve the terminal result while callbacks are still
running. The diagnostics accessor reports the failures recorded by the time
it acquires the ticket lock.

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
