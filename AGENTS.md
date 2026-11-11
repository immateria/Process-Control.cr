# Working on Process-Control

This is an independent Crystal shard. The workspace's root guide applies too.
Do not add runtime shard dependencies, remotes, compatibility aliases or public
types with compound leaf names. Keep each concern's implementation in its own
file under `src/process-control/`.

Read `docs/contracts.md` and `docs/support.md` before changing lifecycle behavior.
`make check` builds the Unix helper into an external cache, then runs formatting
and specs. Use a separate external `CRYSTAL_CACHE_DIR` per concurrent run. Never
put probe copies, test executables or compiler caches in this repository.

The compiler floor is 1.10.0. Use `Clock.now` and `Clock::Instant` for deadlines,
drain budgets and observation timestamps so both stdlib clock APIs stay on the
same timeline. Keep the macro-selected paths buildable on older and current
compilers; their system-sleep semantics are documented in `docs/contracts.md`.

The native Unix helper is original source. It owns the target PID and reaps it;
the managed parent owns the helper. The runtime's helper status must never
become the target's status. Linux uses C-ABI system interfaces; shared C functions
use stdlib declarations, with no conflicting signatures between shards.

The helper is Crystal source under `native/`, built with `-Dwithout_main` and a
custom entry point. Never call `Crystal.main` or use managed allocation, fibers,
exceptions or runtime class initialization there. Fixed buffers use bounded
signed indices and explicit integer checks. The builder audits reachable LLVM,
including callback/global references, in both unoptimized and release output.
Reachable mutable globals are forbidden; a release optimizer can otherwise hide
uninitialized state. The helper materializes native sentinels instead of using
stdlib values that depend on runtime initialization. Run the audit fixtures
and real helper workflow when changing it; do not loosen its native allowlist
without checking the exact operation. Darwin permits no external function calls
and only the exact approved trap and memory-barrier assembly. Its release link
uses dead stripping and must have empty `nm -u` output. Linux helper bindings
stay out of the library's require graph.

Darwin process operations use direct BSD syscalls and Mach traps on ARM64 and
x86-64. Task audit tokens use explicit MIG messages with a dedicated reply right
per read. The helper bootstrap's private spawn layout is gated to Darwin 24;
Mach message and audit-token signaling guards require Darwin 22 and 24
respectively. Audit another release before extending these guards. The managed
Crystal runtime and ordinary I/O still use platform libraries. Apple's linker
also requires the Darwin helper to load libSystem even though it imports no
external symbols. Check the actual native operation before advertising a
capability. A token-aware signal does not qualify a PID-only resume, a permission
probe, or an exit-status source.

Do not claim native containment, Windows runtime support, private FD-table
support, raw-thread support or native PID-reuse qualification from core/provider
tests or cross compilation. Record unavailable and unrun profiles explicitly.

Before declaring completion, run the affected tests, compiler-floor checks and
native profile where available. Keep receipts outside the repository. No commit
or push is implicit in an implementation request.
