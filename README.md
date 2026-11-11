# Process-Control

Process ownership, launch, control and status collection for Crystal applications.
The shard depends on `native-kernel` (`immateria/Native-Kernel.cr`) for reusable
Darwin kernel ABI primitives. Process identity, checked authority, helper protocol
and target collection stay here. The [support matrix](docs/support.md)
records which profiles have run natively.

Crystal 1.10.0 or newer and its native linker are required. Build the Unix
target-owner helper explicitly:

```sh
shards install
crystal run scripts/build-helper.cr
make check
```

The helper is built into the user's cache, outside the checkout. Requiring the
shard does not compile it, open a connection or launch a process. Set
`PROCESS_CONTROL_HELPER` to select an explicitly built helper elsewhere.

The helper is written in Crystal with a custom entry point. It does not start
Crystal's managed runtime, scheduler or child reaper. The build checks generated
LLVM before and after optimization before installing it. The Darwin helper uses
direct kernel traps, and its linked executable must have no undefined imports.
Apple's linker still requires a libSystem loader entry. The Linux helper calls
C-ABI system interfaces. Neither helper uses handwritten C or a separate C
compilation. Cache keys include all helper/build/audit sources, the compiler
description and architecture/OS profile, plus the actual Native-Kernel source
bytes and approved assembly metadata. The builder uses the installed dependency
when it compiles from an external build directory.

The managed Crystal application still uses platform libraries for its runtime
and ordinary I/O. On Darwin, the shard's process launch, inspection and checked
control entry calls use Native-Kernel's direct BSD syscall and Mach primitives.
Its raw profile supports Darwin ARM64/x86-64; dependency source/audit metadata
remains requireable on Linux and Windows. Helper launch uses
a private spawn ABI gated to Darwin 24/25 (macOS 15/26); task messages require macOS 13
or later, and audit-token signaling requires macOS 15 or later. Other Darwin
releases need their own ABI audit and native qualification. See the
[macOS profile](docs/macos.md) for the audited layouts, full consumer CI and
qualification limits.

To select a compiler:

```sh
make CRYSTAL=/path/to/crystal check
```

## Launch and capture

```crystal
require "process-control"

capture = ProcessControl::Stream::Capture.new(
  ProcessControl::Stream::Capture::Budget.new(max_bytes: 65_536))
command = ProcessControl::Command.new("/bin/echo", ["hello"])
  .with_stdio(ProcessControl::Stream::Stdio.new(output: capture))

case launch = command.spawn
in ProcessControl::Spawn::Started
  child = launch.child
  begin
    result = child.complete(
      deadline: ProcessControl::Wait::Deadline.after(5.seconds))
    puts String.new(result.output.not_nil!.bytes)
    p result.child.info
  ensure
    child.close
  end
in ProcessControl::Spawn::Rejected
  raise launch.error
in ProcessControl::Spawn::Pending
  # Own this ticket until resolve or abort accounts for the launch.
  p launch.diagnostic
end
```

Arguments are passed directly. There is no implicit shell. Command builders
return new immutable configurations. Environment, cwd and executable resolution
are captured during each launch; bounded capture retains bytes and marks overflow
while continuing to drain the pipe.

`wait_exit` collects target status. `complete` also waits for configured output.
`close` releases a child's streams and control view; target status remains
collectable afterward. A duplicated control handle has its own close lifetime.
Cooperative stop, forceful kill, signal, suspend and resume return typed delivery
evidence separately from eventual process state.

## Existing processes and groups

Unix PID observation is available through `ProcessControl.observe(pid)` and
the default `Handle.open`. It preserves unknown termination/generation fields.
A sampled PID is refused as control authority.

Request `Capability::Request.wait` to wait on an existing process. Linux uses
a retained pidfd. macOS binds an exit watch to a checked PID generation. Child
status on those platforms still comes from its collector. A Windows process
HANDLE can supply the unsigned exit code after it signals. Close owned handles
when finished.

On macOS, `Capability::Request.control` requests audit-token signaling.
`Inspection.snapshot` enumerates visible PIDs and samples their state and
generation.

On Unix, add `Spawn::Session.new` to a command for a new session or
`Resource::Limit.new(:file, 1024)` for a 1,024-byte file-size limit.
The helper applies both before exec.

On macOS, a collected child's `Wait::Exit::Info#usage` includes CPU times and
peak resident memory in bytes, from the same `wait4` call as its status.
Other status sources leave accounting nil. See the [accounting scope and
units](docs/contracts.md#child-ownership), including already-collected descendants.

On Linux, `Platform::Linux::Cgroup.open(path)` opens a delegated cgroup v2
directory. Its group places targets at creation with `clone3(CLONE_INTO_CGROUP)`.
Population, target exit status and directory lifetime are independent. The
caller creates and removes the directory.

On Windows, `Platform::Windows::Job.create` creates a group whose launcher
places children inside the Job at creation. See the [Windows profile](docs/windows.md).

[Contracts](docs/contracts.md) describe ownership and failure handling.
[Support](docs/support.md) separates implemented behavior, native checks and
planned feature homes. [Behavior](docs/behavior.md) maps runner observations
to the shard's operations and remaining cases.
