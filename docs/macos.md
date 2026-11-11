# macOS process profile

Source audit: 2026-11-11. Process-Control admits the private helper-launch ABI
on Darwin majors 24 and 25, corresponding to macOS 15 and 26. Other majors are
refused before creating launch descriptors or children. Native-Kernel supplies
the stateless spawn entry and ABI sizes/offsets; this shard supplies admission,
buffer contents, ownership, authenticated startup, target collection and cleanup.

## Restricted helper launch

The native64 descriptor is 144 bytes. Its attribute pointer references a
zero-filled 192-byte prefix; a nonzero declared attribute size causes the kernel
to copy that fixed prefix. It does not negotiate a shorter copy. This shard
requests signal defaults, an empty signal mask and close-on-exec by default,
using flags `0x400c`. The default-signal mask excludes SIGKILL and SIGSTOP.
No other private attribute extensions are requested.

File actions encode explicit stdio inheritance and working-directory changes.
Their 8-byte header and 1040-byte records use the dependency's audited offsets,
including the UInt16 open mode and the distinct open/chdir path locations.
Zero-filled storage implements this restricted profile; it is not a replacement
for every default of the platform's general spawn library.

The trusted unmanaged helper starts immediately, then waits for the exact
authenticated `START` frame before creating the logical target. EOF before that
frame ends the helper. After birth, the helper remains the target's sole
collector, including when the managed peer disappears. The runtime's helper
status remains bookkeeping and never becomes target status. Creation is never
automatically replayed after an uncertain result.

Native-Kernel's new `setpgid`, `getpgid` and `getsid` entries expose numeric
mechanisms. Process-Control's existing `Spawn::Session` uses the helper's
session setup; its native integration fixture holds the target alive, verifies
SID and PGID equal its PID, then releases and collects it through its owner.
This does not add a native group controller, a stable group identity or a
descendant-containment guarantee.

## Qualification

The source audit read Apple XNU Darwin 24 `xnu-11417.101.15` and Darwin 25
`xnu-12377.1.9` and `xnu-12377.121.6`. The exact revisions and ABI details are in
[Native-Kernel's process notes](https://github.com/immateria/Native-Kernel.cr/blob/ci/macos-process-next/docs/darwin-process.md).
The used layouts agree across those sources. Exact `.161.*` sources for the
current hosted macOS 26 kernels were unavailable at audit time; runtime evidence
identifies those kernel builds separately.

The versioned workflow tests macOS 15 and 26 on native ARM64 and Intel, with
Crystal 1.10.0 and 1.22.2. `ci/native-kernel.json` pins the exact dependency
commit. The runner verifies that pin before importing dependency tooling and
records both repositories' source hashes before and after execution. It builds
and audits the unmanaged helper at both optimization levels, rejects undefined
imports, and executes the complete spec suite with bounded subprocess cleanup.
The suite includes argv/environment/cwd, stdio, finite limits, session setup,
startup gating, abort, close/collection and descriptor-exhaustion recovery.

Jobs use public standard runners, read-only permissions, no persistent cache
and three-day compressed artifacts. Receipts retain actual host/compiler
identity, stages, source hashes and helper audit evidence. A timeout, setup
failure, malformed summary or absent receipt does not qualify a profile. Local
Rosetta runs remain translated execution, not native Intel qualification.

The ordinary suite does not run the separate high-churn PID-reuse qualification.
Historical macOS 15 reuse/interruption results remain scoped to their recorded
sources and hosts. Protected targets, foreign credentials, arbitrary raw threads
and later kernel majors still require their own qualification.
