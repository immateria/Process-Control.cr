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
Crystal owns only the helper's runtime status. The helper's `Process#wait` result
must never become the target's status. Shared C functions use stdlib declarations;
do not introduce conflicting C signatures when integrating other shards.

The helper is Crystal source under `native/`, built with `-Dwithout_main` and a
custom entry point. Never call `Crystal.main` or use managed allocation, fibers,
exceptions or runtime class initialization there. Fixed buffers use bounded
signed indices and explicit integer checks. The builder audits reachable LLVM,
including callback/global references, in both unoptimized and release output.
Reachable mutable globals are forbidden; a release optimizer can otherwise hide
uninitialized state. The helper materializes native sentinels instead of using
stdlib values that depend on runtime initialization. Run the audit fixtures
and real helper workflow when changing it; do not loosen its native allowlist
without checking the exact operation. The helper's native bindings stay out of
the library's require graph.

Darwin checked control uses private Mach and libproc bindings. Check the actual
native operation before advertising a capability. A token-aware signal does not
qualify a PID-only resume, a permission probe, or an exit-status source.

Do not claim native containment, Windows runtime support, private FD-table
support, raw-thread support or native PID-reuse qualification from core/provider
tests or cross compilation. Record unavailable and unrun profiles explicitly.

Before declaring completion, run the affected tests, compiler-floor checks and
native profile where available. Keep receipts outside the repository. No commit
or push is implicit in an implementation request.
