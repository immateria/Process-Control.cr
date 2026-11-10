# Implementation and qualification

This is the first implementation, created on 2026-11-10. Test receipts are
external to the repository; compile-only checks are not native qualification.

| Surface | Implementation | Native scope |
| --- | --- | --- |
| Identity, observation, capability and diagnostic values | Implemented | Platform-independent core tests |
| Deadlines, cancellation, status fan-out and typed control outcomes | Implemented | Core/provider tests |
| Handle ownership, duplication and pending control leases | Implemented | Provider tests and Unix helper views |
| Immutable command and registration/pending ownership | Implemented | Core/provider tests and Unix launch |
| Target launch, stop, kill, signals, suspend/resume | Unix helper | macOS/Linux profile; other native launchers refused |
| Native pipe endpoints and bounded binary capture | Implemented | Unix child backend |
| Existing-process observation | Unix point query | Presence only; unavailable execution/generation fields remain unknown |
| Existing-process retained control | Planned | Sampled PID control/wait refused |
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
| macOS 15.4.1 ARM64, Apple clang 17 | `make check`, Crystal 1.22.2 | 44 examples pass; formatting and helper compilation pass |
| macOS 15.4.1 ARM64 | Full specs, Crystal 1.21.0 | 44 examples pass |
| Ubuntu Noble ARM64, glibc 2.39, OrbStack kernel 7.0.14, GCC 13.3 | `make check`, Crystal 1.22.2 and 1.21.0 | 44 examples pass on each compiler |
| Workspace cross-target matrix, Crystal 1.22.2 | Instantiated spec compilation for eight targets | All eight build; no linking or execution |
| macOS ARM64, Crystal 1.22.2 | Capture example; cold require with a nonexistent helper override | Example prints captured output; require succeeds without launching the helper |

The native cases cover exec failure, startup ownership, signal reset, finite
waits, binary and bounded capture, argv/environment/cwd, collection after close,
duplicate control, signal status, descendant-held output, repeated attribution
and coexistence with ordinary Crystal process users. Provider cases cover
invalid registration, cleanup retries, pending ownership and group admission/drain
interactions. A simulated protocol disconnect exercises collection failure.

Cross targets are macOS ARM64/x86-64, Linux ARM64/x86-64, Windows ARM64/x86-64,
FreeBSD x86-64 and Android ARM64. Only the macOS and Linux ARM64 runs above are
native execution evidence. No consumer has been migrated to this shard.

The workspace's `docs/reviews/process-control-implementation-2026-11-10.md`
indexes external logs and the source fingerprints used by the Linux runs.
