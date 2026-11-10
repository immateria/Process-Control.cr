# Process-Control

Process ownership, launch, control and status collection for Crystal applications.
The shard has no runtime shard dependencies. It is an early implementation of
the standalone process-control design, with a working macOS/Linux child backend
and provider interfaces for other launchers and containment controllers.

Crystal 1.21.0 or newer is required. Native launching also needs a C11 compiler
to build the small Unix target-owner helper:

```sh
crystal run scripts/build-helper.cr
make check
```

The helper is built into the user's cache, outside the checkout. Requiring the
shard does not compile it, open a connection or launch a process. Set
`PROCESS_CONTROL_HELPER` to select an explicitly built helper elsewhere.

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
observation-only `Handle.open`. It preserves unknown termination/generation
fields. A sampled PID is refused as control authority; it cannot safely wait for
one incarnation across PID reuse.

`Group` implements admission, pending-launch accounting and shutdown orchestration
against an explicit `Containment::Controller`. Native Job/cgroup/process-group
creation is not implemented yet. Requests for those native workflows are refused.

[Contracts](docs/contracts.md) describe ownership and failure handling.
[Support](docs/support.md) separates implemented behavior, native checks and
planned feature homes. [Research](docs/research.md) records the behavior labs
used to choose regression cases.
