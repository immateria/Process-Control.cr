# Working on Process-Control

This is an independent Crystal shard. The workspace's root guide applies too.
Do not add runtime shard dependencies, remotes, compatibility aliases or public
types with compound leaf names. Keep each concern's implementation in its own
file under `src/process-control/`.

Read `docs/contracts.md` and `docs/support.md` before changing lifecycle behavior.
`make check` builds the Unix helper into an external cache, then runs formatting
and specs. Use a separate external `CRYSTAL_CACHE_DIR` per concurrent run. Never
put probe copies, test executables or compiler caches in this repository.

The native Unix helper is original source. It owns the target PID and reaps it;
Crystal owns only the helper's runtime status. The helper's `Process#wait` result
must never become the target's status. Shared C functions use stdlib declarations;
do not introduce conflicting C signatures when integrating other shards.

Do not claim native containment, Windows runtime support, private FD-table
support, raw-thread support or native PID-reuse qualification from core/provider
tests or cross compilation. Record unavailable and unrun profiles explicitly.

Before declaring completion, run the affected tests, compiler-floor checks and
native profile where available. Keep receipts outside the repository. No commit
or push is implicit in an implementation request.
