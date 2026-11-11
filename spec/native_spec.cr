require "./spec_helper"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  module Fixture
    def self.native(command : PC::Command, *, launcher : PC::Spawn::Launcher? = nil) : PC::Child
      result = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(5.seconds))
      case result
      in PC::Spawn::Started
        result.child
      in PC::Spawn::Pending
        result.abort(deadline: PC::Wait::Deadline.after(5.seconds))
        raise "native launch did not complete: #{result.diagnostic.message}"
      in PC::Spawn::Rejected
        raise result.error
      end
    end

    def self.captured(script : String, budget : Int32 = 4096) : PC::Command
      capture = PC::Stream::Capture.new(PC::Stream::Capture::Budget.new(budget))
      PC::Command.new("/bin/sh", ["-c", script]).with_stdio(
        PC::Stream::Stdio.new(input: PC::Stream::Close.new, output: capture, error: capture))
    end
  end

  describe "Unix native process workflow" do
    it "preserves native streams and status when a launch subscriber raises" do
      launcher = PC::Platform::Unix::Launcher.new(capacity: 1)
      command = Fixture.captured("read -r line; printf '%s' \"$line\"; exit 37").with_stdio(
        PC::Stream::Stdio.new(input: PC::Stream::Pipe.new, output: PC::Stream::Capture.new))
      pending = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending)
      pending.on_settle { raise "native launch subscriber failed" }
      child = pending.resolve(deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Started).child
      begin
        pending.callback_failures.map(&.message).should eq(["native launch subscriber failed"])
        child.streams.input.not_nil!.puts "retained streams"
        child.streams.close_input
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        result.child.info.not_nil!.code.should eq(37_u32)
        result.output.not_nil!.bytes.should eq("retained streams".to_slice)
        expect_raises(PC::Error::Ownership) { pending.resolve }
        following = Fixture.native(PC::Command.new("/usr/bin/true"), launcher: launcher)
        begin
          following.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.success?.should be_true
        ensure
          following.close
        end
      ensure
        child.handle.kill
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        child.close
      end
    end

    it "reports native exec failure after accounting for the created target" do
      directory = "/tmp/process-control-exec-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      executable = File.join(directory, "invalid-executable")
      File.write(executable, "not an executable image\n")
      File.chmod(executable, 0o700)
      begin
        result = PC::Command.new(executable).with_stdio(
          PC::Stream::Stdio.new(input: PC::Stream::Pipe.new, output: PC::Stream::Capture.new, error: PC::Stream::Capture.new))
          .spawn(deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Rejected)
        result.attempted.should be_true
        result.cleanup.complete?.should be_true
        diagnostic = result.error.diagnostic.not_nil!
        diagnostic.stage.should eq("exec")
        diagnostic.native_domain.should eq("errno")
        diagnostic.native_code.should eq(Errno::ENOEXEC.value.to_i64)
      ensure
        File.delete(executable)
        Dir.delete(directory)
      end
    end

    it "closes parent pipes when the helper exits before its handshake" do
      launcher = PC::Platform::Unix::Launcher.new("/usr/bin/true", 20.milliseconds)
      command = PC::Command.new("/bin/echo", ["not launched"]).with_stdio(
        PC::Stream::Stdio.new(input: PC::Stream::Pipe.new, output: PC::Stream::Capture.new, error: PC::Stream::Capture.new))
      command.spawn(launcher: launcher).should be_a(PC::Spawn::Rejected)
      descriptors = {% if flag?(:darwin) %} "/dev/fd" {% else %} "/proc/self/fd" {% end %}
      before = Dir.children(descriptors).size
      3.times { command.spawn(launcher: launcher).should be_a(PC::Spawn::Rejected) }
      Dir.children(descriptors).size.should eq(before)
    end

    it "resolves an uncertain launch once and aborts before release when requested" do
      directory = "/tmp/process-control-test-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      wrapper = File.join(directory, "delayed-helper")
      marker = File.join(directory, "created")
      gate = File.join(directory, "gate")
      File.write(wrapper, "#!/bin/sh\nwhile [ ! -e \"$PROCESS_CONTROL_GATE\" ]; do sleep 0.01; done\nexec \"$PROCESS_CONTROL_REAL_HELPER\" \"$@\"\n")
      File.chmod(wrapper, 0o700)
      launcher = PC::Platform::Unix::Launcher.new(wrapper)
      command = PC::Command.new("/bin/sh", ["-c", "printf once >> \"$1\"", "sh", marker])
        .with_env({"PROCESS_CONTROL_REAL_HELPER" => PC::Platform::Unix::Helper.path, "PROCESS_CONTROL_GATE" => gate})
      begin
        result = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(1.millisecond))
        pending = result.as(PC::Spawn::Pending)
        File.write(gate, "release")
        resolved = pending.resolve(deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Started)
        resolved.child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        resolved.child.close
        File.read(marker).should eq("once")
        expect_raises(PC::Error::Ownership) { pending.resolve }
        File.delete(marker)
        File.delete(gate)
        second = command.spawn(launcher: launcher, deadline: PC::Wait::Deadline.after(1.millisecond)).as(PC::Spawn::Pending)
        spawn { File.write(gate, "release") }
        second.abort(deadline: PC::Wait::Deadline.after(5.seconds)).should be_a(PC::Spawn::Rejected)
        File.exists?(marker).should be_false
        second.close.complete?.should be_true
      ensure
        File.delete(marker) if File.exists?(marker)
        File.delete(gate) if File.exists?(gate)
        File.delete(wrapper)
        Dir.delete(directory)
      end
    end

    it "resets target SIGPIPE independently of Crystal's ignored default" do
      child = Fixture.native(Fixture.captured("kill -PIPE $$; exit 99"))
      begin
        result = child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.info.not_nil!.signal.should eq(13)
      ensure
        child.close
      end
    end

    it "closes a foreign inheritable descriptor before releasing the target" do
      directory = "/tmp/process-control-inheritance-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      wrapper = File.join(directory, "open-before-helper")
      reached = File.join(directory, "descriptor-opened")
      File.write(wrapper, <<-SH)
        #!/bin/sh
        exec 9</dev/null
        test -e /dev/fd/9 || exit 70
        printf opened > "$PROCESS_CONTROL_REACHED"
        exec "$PROCESS_CONTROL_REAL_HELPER" "$@"
        SH
      File.chmod(wrapper, 0o700)
      begin
        launcher = PC::Platform::Unix::Launcher.new(wrapper)
        command = Fixture.captured("test ! -e /dev/fd/9").with_env({
          "PROCESS_CONTROL_REACHED"     => reached,
          "PROCESS_CONTROL_REAL_HELPER" => PC::Platform::Unix::Helper.path,
        })
        child = Fixture.native(command, launcher: launcher)
        begin
          result = child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
          File.read(reached).should eq("opened")
          result.info.not_nil!.success?.should be_true
        ensure
          child.close
        end
      ensure
        File.delete(reached) if File.exists?(reached)
        File.delete(wrapper)
        Dir.delete(directory)
      end
    end

    it "preserves unrelated pipe ownership across concurrent failed execs" do
      directory = "/tmp/process-control-failed-exec-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      executable = File.join(directory, "invalid")
      File.write(executable, "not an executable image\n")
      File.chmod(executable, 0o700)
      command = PC::Command.new(executable).with_stdio(
        PC::Stream::Stdio.new(input: PC::Stream::Pipe.new, output: PC::Stream::Capture.new, error: PC::Stream::Capture.new))
      begin
        outcomes = Channel(Exception?).new(4)
        4.times do
          spawn do
            begin
              IO.pipe do |reader, writer|
                reader.read_timeout = 5.seconds
                4.times do
                  result = command.spawn(deadline: PC::Wait::Deadline.after(5.seconds))
                  if result.is_a?(PC::Spawn::Pending)
                    result = result.abort(deadline: PC::Wait::Deadline.after(5.seconds))
                  end
                  rejected = result.as(PC::Spawn::Rejected)
                  rejected.error.diagnostic.try(&.native_code).should eq(Errno::ENOEXEC.value.to_i64)
                  writer << "still owned\n"
                  writer.flush
                  reader.gets.should eq("still owned")
                end
              end
              outcomes.send(nil)
            rescue ex
              outcomes.send(ex)
            end
          end
        end
        failures = Array(Exception?).new(4) do
          select
          when result = outcomes.receive
            result
          when timeout(15.seconds)
            raise "failed exec stress did not settle"
          end
        end
        failures.compact.should be_empty
      ensure
        File.delete(executable)
        Dir.delete(directory)
      end
    end

    it "does not extend repeated finite waits until target exit" do
      child = Fixture.native(Fixture.captured("exec sleep 10"))
      begin
        [1, 5, 15, 30].each do |milliseconds|
          result = child.wait_exit(deadline: PC::Wait::Deadline.after(milliseconds.milliseconds))
          result.state.expired?.should be_true
          result.info.should be_nil
        end
      ensure
        child.handle.kill
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        child.close
      end
    end

    it "captures binary stdout separately from status and stderr" do
      child = Fixture.native(Fixture.captured("printf '\\377\\000abc'; printf error >&2; exit 7"))
      begin
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        result.child.info.not_nil!.code.should eq(7_u32)
        result.output.not_nil!.bytes.should eq(Bytes[255, 0, 97, 98, 99])
        String.new(result.error.not_nil!.bytes).should eq("error")
        bytes = result.output.not_nil!.bytes
        bytes[0] = 0
        result.output.not_nil!.bytes[0].should eq(255)
      ensure
        child.close
      end
    end

    it "bounds retained capture without blocking a larger output" do
      child = Fixture.native(Fixture.captured("printf 123456789", 4))
      begin
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        String.new(result.output.not_nil!.bytes).should eq("1234")
        result.output.not_nil!.truncated.should be_true
      ensure
        child.close
      end
    end

    it "captures argv, environment and cwd before launch" do
      command = PC::Command.new("/bin/sh", ["-c", "printf '%s:%s:%s' \"$MARK\" \"$PWD\" \"$1\"", "sh", "space value"])
        .with_env({"MARK" => "value"}, inherit: false)
        .with_cwd("/tmp")
        .with_stdio(PC::Stream::Stdio.new(output: PC::Stream::Capture.new))
      child = Fixture.native(command)
      begin
        result = child.complete(deadline: PC::Wait::Deadline.after(5.seconds))
        String.new(result.output.not_nil!.bytes).should match(/value:\/(private\/)?tmp:space value/)
      ensure
        child.close
      end
    end

    it "collects target status after child close and keeps a duplicate usable" do
      child = Fixture.native(Fixture.captured("sleep 0.05; exit 42"))
      duplicate = child.handle.duplicate(required: PC::Capability::Request.control)
      begin
        child.close
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(42_u32)
        duplicate.kill.disposition.should be_a(PC::Control::Satisfied)
      ensure
        duplicate.close
        child.retry_cleanup
      end
    end

    it "reports real signal termination without inventing a numeric exit code" do
      child = Fixture.native(Fixture.captured("exec sleep 10"))
      begin
        child.handle.kill.disposition.should be_a(PC::Control::Report::Success)
        result = child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.info.not_nil!.signal.should eq(9)
        result.info.not_nil!.code.should be_nil
      ensure
        child.close
      end
    end

    it "keeps target exit independent of a descendant-held output pipe" do
      child = Fixture.native(Fixture.captured("sleep 0.2 & exit 3"))
      begin
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(3_u32)
        early = child.complete(deadline: PC::Wait::Deadline.after(5.milliseconds))
        early.state.expired?.should be_true
        early.child.info.not_nil!.code.should eq(3_u32)
        child.complete(deadline: PC::Wait::Deadline.after(5.seconds)).state.completed?.should be_true
      ensure
        child.close
      end
    end

    it "keeps repeated child statuses attributed to their targets" do
      12.times do |code|
        child = Fixture.native(Fixture.captured("exit #{code}"))
        begin
          child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(code.to_u32)
        ensure
          child.close
        end
      end
    end

    it "collects target statuses alongside ordinary Crystal process users" do
      8.times do |code|
        ordinary = ::Process.new("/bin/sh", ["-c", "exit #{100 + code}"],
          input: ::Process::Redirect::Close, output: ::Process::Redirect::Close, error: ::Process::Redirect::Close)
        child = nil.as(PC::Child?)
        ordinary_status = nil.as(::Process::Status?)
        begin
          child = Fixture.native(Fixture.captured("exit #{code}"))
          child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(code.to_u32)
        ensure
          child.try(&.close)
          ordinary_status = ordinary.wait
        end
        ordinary_status.not_nil!.exit_code.should eq(100 + code)
      end
    end

    it "refuses unsupported native termination options without killing" do
      child = Fixture.native(Fixture.captured("sleep 0.05; exit 0"))
      begin
        result = child.handle.kill(PC::Control::Kill::Request.new(exit_code: 125_u32))
        result.disposition.should be_a(PC::Control::Refused)
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.code.should eq(0_u32)
      ensure
        child.close
      end
    end
  end
{% end %}
