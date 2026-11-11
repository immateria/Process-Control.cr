require "./spec_helper"

{% if flag?(:windows) %}
  private def windows_fixture(mode : String, args : Enumerable(String) = [] of String) : PC::Command
    PC::Command.new(Process.executable_path.not_nil!, args)
      .with_env({"PROCESS_CONTROL_WINDOWS_FIXTURE" => mode})
  end

  describe "Windows retained process handles" do
    it "validates expected identity and retains an independent duplicate" do
      handle = PC::Handle.open(Process.pid, required: PC::Capability::Request.wait)
      begin
        handle.capabilities.binding.retained?.should be_true
        handle.identity.generation.should_not be_nil
        handle.observe.termination.alive?.should be_true
        handle.kill.disposition.should be_a(PC::Control::Refused)
        handle.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
        cancellation = PC::Wait::Cancellation.new
        cancellation.cancel
        handle.wait_exit(cancel: cancellation).state.cancelled?.should be_true

        stale = PC::Identity.new(Process.pid, generation: PC::Identity::Generation.new(handle.identity.generation.not_nil!.domain, "0"))
        expect_raises(PC::Identity::Mismatch) do
          PC::Handle.open(Process.pid, expected: stale)
        end
        duplicate = handle.duplicate(required: PC::Capability::Request.wait)
        begin
          handle.close.complete?.should be_true
          duplicate.identity.should eq(handle.identity)
          duplicate.observe.termination.alive?.should be_true
          duplicate.close(cancel: cancellation).state.retryable?.should be_true
          duplicate.retry_cleanup.complete?.should be_true
        ensure
          duplicate.close
        end
      ensure
        handle.close
      end
    end
  end

  describe "Windows child launch" do
    it "collects exit 259 after the control owner closes" do
      child = windows_fixture("exit", ["259"]).spawn.as(PC::Spawn::Started).child
      begin
        child.close.complete?.should be_true
        waited = child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds))
        waited.state.completed?.should be_true
        waited.info.not_nil!.domain.windows?.should be_true
        waited.info.not_nil!.code.should eq(259_u32)
        child.exit_info.should eq(waited.info)
      ensure
        child.close
      end
    end

    it "delivers an unsigned exit code through the retained handle and status collector" do
      child = windows_fixture("sleep").with_stdio(PC::Stream::Stdio.new(output: PC::Stream::Close.new)).spawn.as(PC::Spawn::Started).child
      request = PC::Capability::Request.new(%w(handle.observe wait.exit control.kill).map { |name| PC::Capability::Operation.new(name) }, :retained)
      handle = PC::Handle.open(child.identity.pid, required: request, expected: child.identity)
      begin
        code = 0xE000_0001_u32
        handle.kill(PC::Control::Kill::Request.new(code)).disposition.should be_a(PC::Control::Report::Success)
        result = handle.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds))
        result.state.completed?.should be_true
        result.observation.exit_info.not_nil!.raw.should eq(code)
        child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds)).info.not_nil!.raw.should eq(code)
      ensure
        handle.close
        child.handle.kill
        child.close
      end
    end

    it "moves binary bytes through explicitly inherited pipes" do
      stdio = PC::Stream::Stdio.new(input: PC::Stream::Pipe.new, output: PC::Stream::Capture.new, error: PC::Stream::Capture.new)
      child = windows_fixture("echo").with_stdio(stdio).spawn.as(PC::Spawn::Started).child
      begin
        bytes = Bytes[0, 255, 65, 13, 10, 0, 128]
        child.streams.input.not_nil!.write(bytes)
        child.streams.close_input
        completion = child.complete(deadline: PC::Wait::Deadline.after(10.seconds))
        completion.state.completed?.should be_true
        completion.output.not_nil!.bytes.should eq(bytes)
        String.new(completion.error.not_nil!.bytes).strip.should eq("separate")
      ensure
        child.handle.kill
        child.close
      end
    end

    it "round-trips arguments, case-insensitive environment edits and child working directory" do
      args = ["", %q(a\b"c), %q(a b\), "é 🚀", "&|<>%"]
      directory = File.dirname(Process.executable_path.not_nil!)
      command = windows_fixture("describe", args)
      command = command.with_env({"PROCESS_CONTROL_WINDOWS_FIXTURE" => "describe", "PROCESS_CONTROL_TEST" => "first", "process_control_test" => "last"}, inherit: false)
      stdio = PC::Stream::Stdio.new(output: PC::Stream::Capture.new)
      child = command.with_cwd(directory).with_stdio(stdio).spawn.as(PC::Spawn::Started).child
      begin
        completion = child.complete(deadline: PC::Wait::Deadline.after(10.seconds))
        completion.state.completed?.should be_true
        json = JSON.parse(String.new(completion.output.not_nil!.bytes))
        json["args"].as_a.map(&.as_s).should eq(args)
        json["value"].as_s.should eq("last")
        File.expand_path(json["cwd"].as_s).should eq(File.expand_path(directory))
      ensure
        child.handle.kill
        child.close
      end
    end

    it "excludes ambient inheritable handles from the child" do
      attributes = LibC::SECURITY_ATTRIBUTES.new(nLength: sizeof(LibC::SECURITY_ATTRIBUTES).to_u32, bInheritHandle: 1)
      event = WindowsSpec.CreateEventW(pointerof(attributes), 1, 0, nil)
      event.null?.should be_false
      begin
        child = windows_fixture("inheritance", [event.address.to_s]).spawn.as(PC::Spawn::Started).child
        begin
          result = child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds))
          result.state.completed?.should be_true
          result.info.not_nil!.code.should eq(42_u32)
          LibC.WaitForSingleObject(event, 0_u32).should eq(LibC::WAIT_TIMEOUT)
        ensure
          child.handle.kill
          child.close
        end
      ensure
        LibC.CloseHandle(event)
      end
    end
  end
  describe "Windows Job containment" do
    it "refuses an explicit launcher that belongs to a different group" do
      first = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
      begin
        second = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
        result = first.spawn(windows_fixture("sleep"), launcher: second.launcher)
        result.as(PC::Spawn::Rejected).error.should be_a(PC::Error::Ownership)
        first.observe.population.empty?.should be_true
        second.observe.population.empty?.should be_true
      ensure
        first.close
        second.try(&.close)
      end
    end

    it "requires the exact plan to have group admission before native creation" do
      group = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
      begin
        plan = windows_fixture("sleep").prepare(group: group)
        result = group.launcher.not_nil!.launch(plan, deadline: PC::Wait::Deadline.none, cancel: nil)
        result.as(PC::Spawn::Attempt::Rejected).result.error.should be_a(PC::Error::Ownership)
        group.observe.population.empty?.should be_true
      ensure
        group.close
      end
    end

    it "retains a descendant after the launched root exits and terminates it through the job" do
      group = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
      child = group.spawn(windows_fixture("tree").with_stdio(PC::Stream::Stdio.new(output: PC::Stream::Pipe.new))).as(PC::Spawn::Started).child
      begin
        child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds)).state.completed?.should be_true
        output = child.streams.output.not_nil!
        output.native.read_timeout = 5.seconds
        pid = output.gets.not_nil!.strip.to_u32
        descendant = PC::Handle.open(pid, required: PC::Capability::Request.wait)
        begin
          group.observe.population.populated?.should be_true
          code = 0xA000_002A_u32
          group.kill(PC::Control::Kill::Request.new(code)).effect.should be_a(PC::Control::Report::Success)
          result = descendant.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds))
          result.state.completed?.should be_true
          result.observation.exit_info.not_nil!.raw.should eq(code)
          group.wait_empty(deadline: PC::Wait::Deadline.after(10.seconds)).state.completed?.should be_true
        ensure
          descendant.close
        end
      ensure
        group.close
        child.close
      end
    end

    it "terminates a live child when the last owned job handle closes" do
      group = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
      child = group.spawn(windows_fixture("sleep")).as(PC::Spawn::Started).child
      begin
        cancellation = PC::Wait::Cancellation.new
        cancellation.cancel
        group.close(cancel: cancellation).state.retryable?.should be_true
        child.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
        group.retry_cleanup.complete?.should be_true
        child.wait_exit(deadline: PC::Wait::Deadline.after(10.seconds)).state.completed?.should be_true
      ensure
        group.close
        child.close
      end
    end
  end
{% end %}
