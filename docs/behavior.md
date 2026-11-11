# Native process behavior and shard coverage

The reference is [native-test at 0a4f7a8][lab]. Its [native probe run][native]
contains 910 distinct passing cases. It ran 468 under each of two Windows
token profiles and 397 Crystal plus 45 SDK cases on macOS. The supplied r7
handback had four macOS zombie failures. The later run passes those cases
with an independent holder that keeps the target unreaped. [Exploration][matrix]
and [hard exploration][hard] supply additional measurements and failed builds.
See [support](support.md) for Process-Control's separate qualification.

## Identity and completion

| Lab observation | Shard operation or remaining fixture |
| --- | --- |
| Reused PIDs can pick up stale Crystal status. | The Unix helper exclusively reaps the logical target. A disposable Linux PID namespace forced reuse of an unclaimed child's PID for the helper. The target's own status was still collected. |
| Linux pidfd polling sees non-child exit. `waitid(P_PIDFD)` still needs child ownership to collect status. | Retained Linux handles observe, wait and signal via pidfd. The Unix launcher still gets child status from the helper. |
| macOS `NOTE_EXIT` can observe non-children. Late registration can return `ESRCH`, and blocking `kevent` can return `EINTR`. | Native PID reuse checks the original unread event, both registration races, and stale token control against a living replacement. Two million immediate polls run under native signal delivery. A blocking control observes `EINTR` and preserves the queued exit. |
| libproc can omit a zombie when the lookup excludes it. The independent holder confirms unreaped state. | Darwin point observations and bounded snapshots can report a present zombie. A snapshot preserves unavailable rows and truncation. |
| A retained Windows HANDLE remains meaningful after exit. Exit code 259 can be a real terminal code. | A signaled HANDLE establishes exit before reading the unsigned code. The initial wait path samples under the handle lifetime. Registered callbacks require separate qualification. |

## Creation, streams and control

| Lab observation | Shard operation or remaining fixture |
| --- | --- |
| Per-launch Windows HANDLE lists exclude unrelated handles even with concurrent starts. | Windows launch uses explicit stdio inheritance. Extra HANDLE maps and ConPTY need separate launch profiles. |
| Group-targeted Windows CTRL+C can report success without delivery. A detached target may lack a console. | Cooperative stop needs an explicit console, GUI or application protocol. Forceful kill uses `TerminateProcess`. |
| A POSIX target can start in a new session. Changing the group after exec can lose the race. | `Spawn::Session` calls `setsid` before exec. Terminal assignment stays with PTY. |
| Crystal ignores SIGPIPE. Descendant-held pipes delay EOF. | Unix resets target signals and tracks child status separately from stream completion. |
| Concurrent failed execs must preserve unrelated pipes. Foreign descriptors may arrive without close-on-exec. | The native suite checks unrelated pipes across failed execs and injects a foreign inheritable descriptor before the helper. Extra mappings and arbitrary caller IO need their own lifetime fixtures. |
| A stopped Linux child can retain SIGTERM pending until SIGCONT. macOS can terminate a stopped child immediately with the default action. | Stop requests deliver a signal. Resuming a target during shutdown requires an explicit policy. |

## Containment, resources and services

| Lab observation | Shard operation or remaining fixture |
| --- | --- |
| Linux cgroup attach after exec missed descendants under load. `clone3(CLONE_INTO_CGROUP)` placed them at birth. | Group launch checks the opened directory against the controller's retained identity and clones inside it. |
| Cgroups drain independently of zombie reaping. Killing the cgroup can affect subsequent births. Members can move where delegation permits. | Shutdown fences admission and accounts for pending launches before drain. Population describes the selected subtree. |
| Darwin zombie-only groups can return `EPERM`, and PGIDs can be reused. Launchd leaves descendants that moved to another session. | A native group provider needs positive population and authority evidence. |
| Windows Jobs can assign at creation, contain a descendant after its parent exits, and kill on last handle close. | The explicit Job profile uses a creation attribute and reports population, native kill acceptance and drain separately. |
| Windows Job CPU-time enforcement ran on a roughly seven-second pass. Readback was separate from enforcement. | Job limits and notifications need distinct qualification. Build 17763 remains an open comparison. |
| POSIX file-size and CPU limits apply per process. Darwin address-space limits do not cap physical footprint. | `Resource::Limit` applies finite CPU, file, core and descriptor bounds before exec. A native file fixture measures the enforced write limit. |
| FreeBSD process descriptors and reaper tree kill worked on 14.3 and 15.0. The Crystal supervision spec failed to compile. | Process descriptors and tree control are candidates for separate FreeBSD profiles. |
| Landlock and seccomp apply before exec and depend on the caller's security context. AppContainer changes the child's token and access. | Future `Security` and `Isolation` extensions need per-mechanism setup and enforcement tests. |
| Launchd and the SCM own service lifetimes. Readiness and watchdogs have their own transport and deadlines. | `Service`, `Supervision` and `Event` need separate authority and settlement. The pinned hard-run Windows service build failed before its runtime step. |

[lab]: https://github.com/immateria/native-test/blob/0a4f7a89d7c90449748376012ff410863eb51114/explore/FINDINGS.md
[native]: https://github.com/immateria/native-test/actions/runs/42072754868
[matrix]: https://github.com/immateria/native-test/actions/runs/42072755136
[hard]: https://github.com/immateria/native-test/actions/runs/42072755013
