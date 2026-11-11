# Implementation and qualification

The shard was created on 2026-11-10. The [behavior map](behavior.md) records
the lab's evidence. Test receipts for the shard live outside the repository.

| Surface                                                            | Implementation                                                         | Native scope                                                                                            |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Identity, observation, capability and diagnostic values            | Implemented                                                            | Platform-independent core tests                                                                         |
| Deadlines, cancellation, status fan-out and typed control outcomes | Implemented                                                            | Core/provider tests                                                                                     |
| Handle ownership, duplication and pending control leases           | Implemented                                                            | Provider tests and Unix helper views                                                                    |
| Immutable command and registration/pending ownership               | Implemented                                                            | Core/provider tests and Unix launch                                                                     |
| Target launch, stop, kill, signals, suspend/resume                 | Crystal helper; direct Darwin bootstrap and target operations          | Darwin 24/25 admission and Linux; see macOS qualification below                               |
| Unix target setup                                                  | Session and finite POSIX limits                                        | macOS and Linux                                                                                         |
| Native pipe endpoints and bounded binary capture                   | Implemented                                                            | Unix native tests and Windows code generation                                                           |
| Existing-process observation                                       | Unix point query; Darwin Mach reference observation                    | Darwin sampled queries can identify a present zombie, and checked acquisition adds PID-version evidence |
| Existing-process checked control                                   | Direct Darwin audit-token signaling                                    | macOS 15 or later by source guard; measured on macOS 15.4.1 ARM64 and Rosetta x86-64                      |
| Existing-process exit wait                                         | Darwin kqueue, Linux pidfd, Windows process HANDLE                     | macOS and Linux ARM64 native tests; Windows code generation                                             |
| Existing-process retained control                                  | Linux pidfd and Windows process HANDLE                                 | Linux ARM64 native tests; Windows code generation                                                       |
| Process inspection                                                 | Darwin sampled snapshot                                                | macOS ARM64 native tests                                                                                |
| Group orchestration and controller interface                       | Implemented                                                            | Deterministic controller tests                                                                          |
| Linux cgroup v2                                                    | Explicit delegated directory, birth placement, freezer, kill and drain | Delegated Linux ARM64 native tests                                                                      |
| Windows child launch and Jobs                                      | Explicit stdio inheritance and creation-time Job placement             | Windows x64 and ARM64 code generation                                                                   |
| Native POSIX groups, late attach and registered Windows waits      | Planned                                                                | See the behavior map                                                                                    |
| FreeBSD descriptors/reapers and Android native launch              | Planned                                                                | No native support claimed                                                                               |
| In-place/extra descriptor maps and descriptor execution            | Planned                                                                | Extensions currently refused before creation                                                            |
| Detached launch and external manager transfer                      | Planned                                                                | No implicit detach                                                                                      |

Permanent optional homes remain `Stream`, `IPC`, `Inspection`, `Resource`,
`Security`, `Isolation`, `Event`, `Supervision`, `Service` and native `Platform`
extensions. They are not loaded as empty successful backends. Pipelines,
readiness/liveness, restart policy, credentials, aggregate resource accounting,
isolation and service-manager integration remain in the design inventory.

The native tests exercise forced helper PID reuse inside a disposable Linux
namespace and actual Darwin PID reuse on macOS 15.4.1 ARM64. Privileged
credentials, foreign execution contexts, private FD tables,
hostile same-UID callers and filesystem confinement remain unqualified. The
helper path is a trusted caller-selected executable. A Linux cgroup controller
covers its selected subtree under the stated delegation.

## First implementation checks on 2026-11-10

The dated records through the review-regression section describe checkpoints
before the direct Darwin rewrite. Their counts and source scope are historical;
the rewrite's verification is recorded separately below.

| Environment                                                           | Check                                                            | Result                                                                        |
| --------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| macOS 15.4.1 ARM64, Apple clang 17                                    | `make check`, Crystal 1.10.0, 1.21.0 and 1.22.2                  | 79 examples pass on each compiler; formatting and both helper audits pass     |
| macOS 15.4.1 x86-64 under Rosetta                                     | `make check`, Crystal 1.10.0 with Intel OpenSSL/libevent         | 79 examples pass; both helper audits pass                                     |
| Ubuntu Noble x86-64 under Rosetta, glibc 2.39, OrbStack kernel 7.0.14 | `make check`, official bundled Crystal 1.10.0                    | 60 examples pass; both helper audits pass                                     |
| Ubuntu Noble ARM64, glibc 2.39, OrbStack kernel 7.0.14, GCC 13.3      | `make check`, Crystal 1.22.2                                     | 60 examples pass                                                              |
| Workspace cross-target matrix, Crystal 1.22.2                         | Instantiated spec compilation for eight targets                  | All eight build; no linking or execution                                      |
| macOS ARM64, Crystal 1.22.2                                           | Capture example; cold require with a nonexistent helper override | Example prints captured output; require succeeds without launching the helper |
| macOS ARM64, Crystal 1.22.2                                           | Checked self-observation with a nonexistent helper override      | Acquisition, observation and close succeed                                    |

The native cases cover exec failure, startup ownership, signal reset, finite
waits, binary and bounded capture, argv/environment/cwd, collection after close,
duplicate control, signal status, descendant-held output, repeated attribution
and coexistence with ordinary Crystal process users. Provider cases cover
invalid registration, cleanup retries, pending ownership and group admission/drain
interactions. A simulated protocol disconnect exercises collection failure.
Additional protocol cases cover
UInt64 boundaries, numeric overflow, embedded NUL and a peer that cannot receive
an acknowledgment. Both unoptimized and release LLVM must pass the runtime
auditor; its fixtures reject managed calls, uninitialized mutable globals,
constructors, indirect calls and unapproved imports.

Cross targets are macOS ARM64/x86-64, Linux ARM64/x86-64, Windows ARM64/x86-64,
FreeBSD x86-64 and Android ARM64. The `make check` rows record execution on their
stated OS and architecture. Rosetta runs establish correctness in that translated
environment. No consumer has been migrated to this shard.

The compiler floor is 1.10.0. Clock selection uses the available stdlib type at
compile time; [contracts](contracts.md) records the system-sleep distinction.
Explicit collection types, portable descriptor flags and executable checks keep
older compilers on the same ownership/control path. Crystal 1.10 uses its default
optimization for the development IR because it predates the `-O` option; the
installed helper still uses `--release`. Both LLVM audits run. On this Mac,
its older object files produce linker warnings about
missing platform load commands; compilation and native tests pass. The ordinary
Linux tarball needed an unavailable libevent development library, so the floor
run used the official bundled tarball without changing system packages. Linux
ARM64 execution below 1.21 remains unrun.

The Crystal helper replacement record below indexes these runs and their
source fingerprints. The original 44-example baseline has its own historical
implementation record in the workspace.

## Crystal helper replacement on 2026-11-10

The production C source was removed on 2026-11-10. The helper defines its own
entry point and never starts Crystal's managed runtime. Native signal sentinels
and callback pointers are constructed without stdlib runtime initialization.
Private helper bindings do not enter the library's require graph.

At this checkpoint both platform helpers called C-ABI system interfaces through
Crystal FFI, including `LibC.fork` and `LibC.waitpid`. The change replaced the
source language and runtime initialization. The later direct Darwin rewrite
replaced that platform's process entry calls; Linux still uses the C-ABI path.

All four macOS/Linux ARM64/x86-64 helper targets produce code and pass both
unoptimized and release LLVM audits. A compiler-driver wrapper that rejects
`.c` inputs allows the complete helper build; native linking remains required.

The workspace's `docs/reviews/process-control-crystal-helper-2026-11-10.md`
records the review fixes, complete verification and original-checkout delivery.
The code auditor checks the supported compiler artifacts; it is not a general
LLVM validator or a proof of every native function's behavior. Inputs and the
selected compiler/linker are trusted and must remain stable during a build.

## Darwin checked control

The macOS 15.4.1 ARM64 and Rosetta x86-64 suites exercise real SIGTERM, SIGKILL, POSIX
stop/continue, duplicate/close, and a wrong PID-version token on owned targets.
At this checkpoint the helper collected child status. The fixture changes the token's
generation without forcing PID reuse. The tests also pin native `EINVAL` for
signal zero and `ESRCH` for the collected target. Driver cases exercise missing
support, partial acquisition, Mach/errno provenance, context refusal and cleanup
when native I/O cannot complete. See [contracts](contracts.md) for the API scope.

The exit-wait specs observe a helper-owned non-child while its native parent
collects status. They cover a finite wait, cancellation, closing a pending
view, shared one-shot evidence across duplicates and uncertain queue cleanup.
The registration-race fixtures refuse a substituted generation and retain
`ESRCH` provenance. A stopped independent parent holds a zombie so that the
point query can establish both presence and termination before reaping.

Other macOS releases, protected/foreign targets, changed credentials,
raw fork integration and native Windows control remain unqualified.
The workspace's `docs/reviews/process-control-darwin-2026-11-10.md` records the
review, test receipts and translated-build setup.

## Expanded profiles on 2026-11-10

The delivered macOS ARM64 suite passed 97 examples on Crystal 1.10.0 and
1.22.2. The delegated Linux ARM64 suite passed 79 examples on Crystal 1.22.2,
and the isolated PID reuse case passed separately. The cross-target spec
check passed all eight targets.

The macOS ARM64 suite exercises checked exit watches and process snapshots.
It also reports an independently held zombie as present and terminated. The
fixture's parent subsequently collects its own exit status.

The delegated Linux ARM64 suite requires both pidfd and cgroup birth support.
It checks the target's membership before running the workload, kills a
descendant that creates its own session, and observes cgroup drain separately
from target exit status. It also exercises freezer admission and rejection of
a mismatched cgroup identity. A separate user/PID namespace spec forces reuse
of the Unix helper's PID and checks the logical target's exit code. The
translated x86-64 Linux environment returns `ENOSYS` for pidfd acquisition and
`clone3`. The Crystal 1.10.0 suite on that host passed 73 examples with four
pidfd cases pending. Its delegated cgroup observation, freeze/thaw and kill
are independent of those syscalls.

The [Windows profile](windows.md) describes the retained handle, child launch
and Job paths. The Windows specs instantiate on both MSVC architectures.
The x86-64 GNU build passed 51 examples under CrossOver 25.0.1. Native Windows
runtime qualification remains open.

## Review regressions on 2026-11-10

The callback regression covers launch publication, abort settlement, late and
reentrant subscribers, control leases and stream ownership. A failing subscriber
records a diagnostic while all remaining subscribers receive their notification.
Two gated publication cases exercise abort before transfer and competing
resolvers while the group still owns its settlement lease.

The Linux cases replace a real cgroup pathname after admission, and drop an
authenticated `STARTED` response after confirming birth. The replacement is
refused with setup-stage `ESTALE`. Lost acknowledgment retains the launch ticket
through target collection and empty population. The test fixture disposes its
own controller descriptors during teardown after asserting the public cleanup
result.

Darwin native cases reap the target before registration and before the
post-registration identity check, verifying `ESRCH` provenance and native cleanup.
A gated zombie case verifies the generation while the target remains unreaped.
The additional native qualification below exercises actual PID-generation
reuse, immediate polling during signal delivery, and a blocking `EINTR` control.

Windows startup tests create suspended processes and inject failures at identity
query, duplication, resume, termination, cleanup observation and close. They
check retained ownership, exact diagnostics and handle counts after fixture
cleanup. These injections qualify the state transitions in the tested
environment. Native Windows rollback qualification still requires Windows runs.

| Environment | Result |
| --- | --- |
| macOS 15.4.1 ARM64, Crystal 1.22.2 and 1.10.0 | `make check` passes 107 examples on each compiler |
| Delegated Linux ARM64, Crystal 1.22.2, mandatory pidfd and cgroup birth | 89 examples pass with no pending cases |
| Windows x86-64 GNU under CrossOver 25.0.1 | 64 examples pass, including six startup failure cases |
| Crystal 1.22.2 cross-target matrix | All eight targets compile |
| Crystal 1.10.0, Linux ARM64 and Windows x86-64 MSVC | Spec compilation passes |

Receipts and independent review probes remain outside the repositories. Helper
receipts bind the declared source fingerprint and audited IR. The compiler,
stdlib and linker inputs use the documented trusted, stable toolchain assumption.

## Native Darwin qualification

Run the opt-in native qualifications with the selected compiler.

```sh
crystal run scripts/check-darwin.cr
```

The runner builds two unmanaged Crystal fixtures outside the repository and
audits their unoptimized and release LLVM. It records source, executable and IR
digests with the compiler description. The source manifest covers local Crystal
files under `src`, `native` and `spec`, plus the runner and auditor, and separately
records the installed Native-Kernel dependency's source digests. The runner
checks those inputs again after execution. Both fixtures now use the direct
Darwin trap engine. Their LLVM audits allow no external function imports and
only the exact approved trap and memory-barrier assembly. After native linking
with dead stripping, each executable must also have empty `nm -u` output.
Verifier regressions pin the production build's default profile.

The PID factory forks and reaps one child at a time, with a 250,000-birth limit.
It holds a replacement alive at the original PID. The observer retains the
original Mach references and its unread exit event through reuse. Both native
registration gates span the actual reuse, and both reject the replacement
generation. Stale stop, kill, suspend and resume report `ESRCH`. A separate
replacement handshake follows each stale request. The replacement's fresh
checked handle can kill it, and its native parent collects SIGKILL. A control
pipe EOF case verifies collection when the caller abandons an unreleased target.

The interruption fixture runs two million immediate polls while a native child
delivers signals to a native handler. It checks exactly one target exit event.
A blocking kqueue control observes real `EINTR` and then retrieves the target's
exit event through immediate polling. On the host-matching XNU version, the
immediate flag returns before the interruptible wait. The native receipts
distinguish these two paths. [XNU kqueue scan](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.101.15/bsd/kern/kern_event.c#L7535)

The final direct-kernel qualification passes all three cases on macOS 15.4.1
ARM64 with Crystal 1.22.2 and 1.10.0. Each manifest binds 127 local source
inputs and both fixture executables and IR artifacts. All source and artifact
hashes match the delivered files; both executables have no undefined imports.
The ordinary suite keeps these process-churn qualifications opt-in.
Raw fork inside a managed Crystal process, foreign credentials, other macOS
releases and other architectures require their own qualification.

## Direct Darwin rewrite on 2026-11-10

The shard's ARM64 and x86-64 Darwin process entry calls now use BSD syscalls and
Mach traps directly. This covers task-name rights, explicit `task_info` MIG
messages for audit tokens, audit-token signaling, kqueue exit watches and kernel
process-info queries. Token reads own a reply receive right for each exchange
and release it on success or native failure. The shared trap engine preserves
both native result registers and captures BSD error carry before generated code
can change it. The helper uses the same engine for fork, wait, signal, descriptor,
setup and exec operations, with its own signal trampoline and no managed runtime.

The message path's source guard requires Darwin 22 (macOS 13) or later. The
audit-token signal guard requires Darwin 24 (macOS 15) or later. These guards
describe availability derived from the native interfaces, not completed runs on
every permitted release. The managed helper bootstrap uses the private spawn
attribute and action layouts read from XNU `xnu-11417.101.15`; it accepts only
Darwin 24. Extending that private layout to another major release requires a
separate source audit and native qualification. The source pins and field sizes
are recorded beside the bootstrap and trap implementations.

The trusted unmanaged helper runs immediately after spawn. It cannot create
the logical target before receiving the exact authenticated `START` frame.
Control-channel EOF before that frame ends the helper; afterward it continues
collecting its target if the peer disappears. The managed runtime's helper
status remains bookkeeping and never supplies target identity or status.

Darwin helper builds audit unoptimized and release LLVM with an empty native
function allowlist and exact assembly templates. The native release link uses
dead stripping, then rejects any undefined symbol reported by `nm -u`. The four
helper artifacts for Crystal 1.22.2 and 1.10.0 on ARM64 and x86-64 have empty
import tables. They also complete direct helper handshakes, target status
collection and stop/continue/terminate checks on this Mac, with x86-64 under
Rosetta. A separate inherited-descriptor probe covers 1,800 descriptors on both
current-compiler architectures.

Apple's linker still requires a libSystem loader entry for these unmanaged
executables. An empty undefined-symbol table records that the helper imports no
external functions; it does not remove that loader requirement. The managed
Crystal runtime and ordinary file, socket and stream I/O still use platform
libraries. Linux continues to use its C-ABI helper and process interfaces.

Review found a compiler-inserted `_memset` in the managed x86-64 token-read
buffer initialization. The reply buffer now initializes only its complete
40-byte request, then reads a reply payload only after validating its declared
size. The release-query output buffer likewise relies on the syscall's validated
returned length. Current and floor x86-64 wrapper objects have no memory-library
call relocations in the token-read success path. On ARM64, each compiler also
completed 2,000 successful and 2,000 invalid-destination token reads without
increasing the number of Mach names.

Review reproduced a startup leak under descriptor exhaustion in an intermediate
suspended-helper bootstrap. The helper now runs immediately and uses its existing
authenticated startup gate. An isolated reexec regression exhausts its own FD
table, checks rejection and helper exit, then successfully reuses the launcher's
single slot. It runs on both compilers and both macOS architectures.

| Final profile | Result |
| --- | --- |
| macOS 15.4.1 ARM64, Crystal 1.22.2 and 1.10.0 | 115 examples pass on each compiler |
| macOS 15.4.1 x86-64 under Rosetta, both compilers | 115 examples pass on each compiler |
| Native Darwin reuse/interruption, ARM64, both compilers | Three cases pass on each compiler; real PID reuse and blocking EINTR |
| Delegated Linux ARM64, mandatory pidfd and cgroup birth | 93 examples pass; no pending cases |
| Crystal 1.22.2 cross-target matrix | All eight targets compile |

Linux LLVM 22 emitted signed-maximum and vector trailing-zero intrinsics from
the shared pure Crystal loops. The auditor now accepts those specific intrinsic
families, with failing-before/passing-after fixtures. Other experimental
intrinsics remain refused. No native function allowance was added.

The workspace's `docs/reviews/process-control-darwin-kernel-2026-11-10.md`
indexes final source-bound receipts, review fixes and qualification limits.

## Native-Kernel extraction on 2026-11-10

Reusable Darwin ARM64/x86-64 kernel entry, result conventions, ABI records and
stateless descriptor, process, resource, signal, event and Mach primitives now
come from `native-kernel` (`immateria/Native-Kernel.cr`). Process-Control retains
identity and checked authority, caller-context ownership, helper protocol,
target signal reset policy, collection and cleanup decisions. This dependency
does not migrate PTY or File-Lock.

The dependency's raw require is limited to Darwin ARM64/x86-64. Source and audit
metadata remain portable, so Linux and Windows still compile Process-Control's
own profiles. Build tooling fingerprints the actual installed dependency source
bytes and assembly metadata, supplies its path to external helper builds, and
retains both LLVM audits and the final Darwin empty-import check. Qualification
receipts separately enumerate dependency digests and recheck them after execution.
The pre-extraction example counts and source manifests above remain historical
evidence; they do not establish qualification of the extracted revision.


### Extraction qualification on 2026-11-10

| Final check | Result |
| --- | --- |
| Native-Kernel, Crystal 1.22.2 and 1.10.0, ARM64 and Rosetta x86-64 | 14 specs per profile; unmanaged development/release audits, empty imports and execution pass |
| Process-Control, both compilers and both macOS architectures | 118 specs per profile; helper audits and empty imports pass |
| Original Process-Control checkout, current ARM64 compiler | 118 specs pass with the workspace-installed dependency |
| Delegated Linux ARM64, mandatory pidfd and cgroup birth | 96 specs pass |
| Native Darwin reuse/interruption, both compilers | Three cases pass per compiler; actual PID reuse and blocking EINTR |
| Current cross-target matrix | Process-Control builds all eight; Native-Kernel builds both Darwin cells and refuses the other six raw profiles as specified |

All executed suites have zero failures, errors or pending cases. Each native
qualification manifest binds 124 local inputs and 15 Native-Kernel sources;
all hashes match the delivered source and artifacts. Dependency source/profile
mutation changes the helper fingerprint, and a builder with stale embedded
sources refuses installation. Fresh independent core, build and integration
reviews found no remaining source blocker. Raw receipts remain outside the
repositories; the workspace review indexes them.

## macOS process profiles on 2026-11-11

The bootstrap now selects Native-Kernel's audited Darwin 24/25 spawn profile.
Unknown majors remain refused before launch effects. The [macOS profile](macos.md)
records the restricted attribute subset, source pins and complete consumer CI
gate. Group/session queries are stateless dependency primitives; the held-target
session fixture checks the existing `Spawn::Session` behavior. A native group
controller and descendant containment are not introduced by this batch.

The workflow qualifies all eight native macOS 15/26, ARM64/Intel and
Crystal 1.10.0/1.22.2 combinations against an exact dependency commit. A profile
is qualified only by a passing source-bound receipt. Historical counts above
remain evidence for their original revisions. PID reuse/interruption, foreign
credentials and protected-target behavior retain their separately recorded
scope; the ordinary CI suite does not imply those qualifications.
