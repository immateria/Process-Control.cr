require "../src/process-control"

capture = ProcessControl::Stream::Capture.new
command = ProcessControl::Command.new("/bin/echo", ["hello from Process-Control"])
  .with_stdio(ProcessControl::Stream::Stdio.new(output: capture))

case launch = command.spawn
in ProcessControl::Spawn::Started
  child = launch.child
  begin
    result = child.complete(deadline: ProcessControl::Wait::Deadline.after(5.seconds))
    STDOUT.write(result.output.not_nil!.bytes)
    exit 1 unless result.state.completed? && result.child.info.try(&.success?)
  ensure
    child.close
  end
in ProcessControl::Spawn::Rejected
  abort launch.error.message
in ProcessControl::Spawn::Pending
  launch.abort(deadline: ProcessControl::Wait::Deadline.after(5.seconds))
  abort "launch remains pending: #{launch.diagnostic.message}"
end
