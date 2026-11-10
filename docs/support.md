# Implementation and qualification

This is the first implementation, created on 2026-11-10. Test receipts are
external to the repository; compile-only checks are not native qualification.

| Surface | Implementation | Native scope |
| --- | --- | --- |
| Identity, observation, capability and diagnostic values | Implemented | Platform-independent core tests |
| Deadlines, cancellation, status fan-out and typed control outcomes | Implemented | Core/provider tests |
| Handle ownership, duplication and pending control leases | Implemented | Provider tests and Unix helper views |
| Immutable command and registration/pending ownership | Implemented | Core/provider tests and Unix launch |
| Target launch, stop, kill, signals, suspend/resume | Crystal helper | macOS/Linux profile; other native launchers refused |
| Native pipe endpoints and bounded binary capture | Implemented | Unix child backend |
| Existing-process observation | Unix point query; Darwin Mach reference observation | Presence only; checked Darwin acquisition adds PID-version evidence |
| Existing-process checked control | Darwin audit-token signaling | Stop, kill, POSIX signals and stop/continue where the runtime API and acquisition are available |
| Existing-process retained control/wait | Planned | No process-object handle or exit source in the Darwin profile |
| Group orchestration and controller interface | Implemented | Deterministic controller tests |
| Group attach, suspend/resume and asynchronous creation | Planned | Their concern types/controller seam exist; public operations await native profiles |
| Native groups, cgroups and Windows Jobs | Planned | Default native creation refused |
| Windows native handles, launch and registered waits | Planned | No Windows runtime support claimed |
| FreeBSD descriptors/reapers and Android native launch | Planned | No native support claimed |
| In-place/extra descriptor maps and descriptor execution | Planned | Extensions currently refused before creation |
| Detached launch and external manager transfer | Planned | No implicit detach |

Permanent optional homes remain `Stream`, `IPC`, `Inspection`, `Resource`,
`Security`, `Isolation`, `Event`, `Supervision`, `Service` and native `Platform`
extensions. They are not loaded as empty successful backends. Pipelines,
readiness/liveness, restart policy, credentials, resource limits, isolation and
service-manager integration remain in the design inventory.

The native tests do not establish real kernel PID-wraparound behavior,
privileged credentials, namespace changes, private FD tables, hostile same-UID
callers, raw-thread integration, filesystem confinement or descendant containment.
The helper path is a trusted caller-selected executable. The backend's control
scope is its logical target, not an arbitrary descendant tree.

## Checked on 2026-11-10

| Environment | Check | Result |
| --- | --- | --- |
| macOS 15.4.1 ARM64, Apple clang 17 | `make check`, Crystal 1.10.0, 1.21.0 and 1.22.2 | 79 examples pass on each compiler; formatting and both helper audits pass |
| macOS 15.4.1 x86-64 under Rosetta | `make check`, Crystal 1.10.0 with Intel OpenSSL/libevent | 79 examples pass; both helper audits pass |
| Ubuntu Noble x86-64 under Rosetta, glibc 2.39, OrbStack kernel 7.0.14 | `make check`, official bundled Crystal 1.10.0 | 60 examples pass; both helper audits pass |
| Ubuntu Noble ARM64, glibc 2.39, OrbStack kernel 7.0.14, GCC 13.3 | `make check`, Crystal 1.22.2 | 60 examples pass |
| Workspace cross-target matrix, Crystal 1.22.2 | Instantiated spec compilation for eight targets | All eight build; no linking or execution |
| macOS ARM64, Crystal 1.22.2 | Capture example; cold require with a nonexistent helper override | Example prints captured output; require succeeds without launching the helper |
| macOS ARM64, Crystal 1.22.2 | Checked self-observation with a nonexistent helper override | Acquisition, observation and close succeed |

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
unoptimized helper build because it predates the `-O` option. The two LLVM audits
still run. On this Mac, its older object files produce linker warnings about
missing platform load commands; compilation and native tests pass. The ordinary
Linux tarball needed an unavailable libevent development library, so the floor
run used the official bundled tarball without changing system packages. Linux
ARM64 execution below 1.21 remains unrun.

The Crystal helper replacement record below indexes these runs and their
source fingerprints. The original 44-example baseline has its own historical
implementation record in the workspace.

## Crystal helper replacement

The production C source was removed on 2026-11-10. The helper defines its own
entry point and never starts Crystal's managed runtime. Native signal sentinels
and callback pointers are constructed without stdlib runtime initialization.
Private helper bindings do not enter the library's require graph.

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
The original helper still collects child status. The fixture changes the token's
generation without forcing PID reuse. The tests also pin native `EINVAL` for
signal zero and `ESRCH` for the collected target. Driver cases exercise missing
support, partial acquisition, Mach/errno provenance, context refusal and cleanup
when native I/O cannot complete. See [contracts](contracts.md) for the API scope.

Other macOS releases, protected/foreign targets, changed credentials, actual
PID reuse, raw fork integration and native Windows control remain unqualified.
The workspace's `docs/reviews/process-control-darwin-2026-11-10.md` records the
review, test receipts and translated-build setup.
