require "./spec_helper"
require "./support/darwin"

{% if flag?(:darwin) %}
  module Fixture::Darwin
    def self.child : PC::Child
      attempt = PC::Command.new("/bin/sleep", ["30"]).spawn(deadline: PC::Wait::Deadline.after(5.seconds))
      case attempt
      in PC::Spawn::Started
        attempt.child
      in PC::Spawn::Pending
        attempt.abort(deadline: PC::Wait::Deadline.after(5.seconds))
        raise "fixture launch remained pending"
      in PC::Spawn::Rejected
        raise attempt.error
      end
    end

    def self.collect(child : PC::Child) : Nil
      child.handle.kill
      child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
      child.close
    end

    def self.expect_stopped(child : PC::Child, stopped : Bool) : Nil
      deadline = PC::Wait::Deadline.after(5.seconds)
      loop do
        output = IO::Memory.new
        result = Process.run("/bin/ps", ["-o", "state=", "-p", child.identity.pid.to_s], output: output)
        state = output.to_s.strip
        return if result.success? && !state.empty? && state.starts_with?('T') == stopped
        raise "fixture did not reach expected stopped state" if deadline.expired?
        deadline.pause
      end
    end
  end

  describe "Darwin existing-process control" do
    it "delivers SIGTERM while the original child owner collects its status" do
      child = Fixture::Darwin.child
      handle = nil.as(PC::Handle?)
      begin
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.control)
        handle.request_stop.disposition.should be_a(PC::Control::Report::Success)
        result = child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.info.not_nil!.signal.should eq(15)
      ensure
        handle.try(&.close)
        Fixture::Darwin.collect(child)
      end
    end

    it "acquires checked identity, duplicates the Mach right, and keeps waits separate" do
      child = Fixture::Darwin.child
      handle = nil.as(PC::Handle?)
      copy = nil.as(PC::Handle?)
      match = nil.as(PC::Handle?)
      begin
        checked = PC::Capability::Request.new([PC::Capability::Operation.new("handle.observe"), PC::Capability::Operation.new("control.kill")], :checked)
        handle = PC::Handle.open(child.identity.pid, required: checked)
        handle.capabilities.binding.checked?.should be_true
        observation = handle.observe
        observation.presence.present?.should be_true
        observation.termination.unknown?.should be_true
        observation.identity.should eq(handle.identity)
        generation = handle.identity.generation.not_nil!
        generation.domain.should eq("darwin.audit.pidversion")
        match = PC::Platform::Darwin.open(child.identity.pid, expected: handle.identity)
        match.close.complete?.should be_true
        retained = PC::Capability::Request.new([PC::Capability::Operation.new("control.kill")], :retained)
        expect_raises(PC::Error::Unsupported) { PC::Handle.open(child.identity.pid, required: retained) }
        handle.wait_exit.state.failed?.should be_true
        copy = handle.duplicate(required: checked)
        handle.close.complete?.should be_true
        handle.kill.disposition.should be_a(PC::Control::Refused)
        copy.observe.presence.present?.should be_true
        copy.identity.should eq(handle.identity)
        copy.kill.disposition.should be_a(PC::Control::Report::Success)
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.signal.should eq(9)
        copy.close.complete?.should be_true
      ensure
        match.try(&.close)
        copy.try(&.close)
        handle.try(&.close)
        Fixture::Darwin.collect(child)
      end
    end

    it "stops and continues through token-bound POSIX signals" do
      child = Fixture::Darwin.child
      handle = nil.as(PC::Handle?)
      begin
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.control)
        handle.suspend.disposition.should be_a(PC::Control::Report::Success)
        Fixture::Darwin.expect_stopped(child, true)
        handle.resume.disposition.should be_a(PC::Control::Report::Success)
        Fixture::Darwin.expect_stopped(child, false)
        handle.signal(PC::Control::Signal.new("posix", 9)).disposition.should be_a(PC::Control::Report::Success)
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.signal.should eq(9)
      ensure
        handle.try(&.close)
        Fixture::Darwin.collect(child)
      end
    end

    it "rejects a wrong pidversion and does not treat signal zero as a native probe" do
      child = Fixture::Darwin.child
      driver = PC::Internal::Darwin::Native.new
      port = 0_u32
      begin
        port, code = driver.open(child.identity.pid.to_i32)
        code.should eq(0)
        words, count, code = driver.read(port)
        code.should eq(0)
        count.should eq(8)
        token = PC::Internal::Darwin::Token.new(words)
        token.pid.should eq(child.identity.pid)
        words[7] = words[7] &+ 1_u32
        stale = PC::Internal::Darwin::Token.new(words)
        driver.signal(stale, 15).should eq(Errno::ESRCH.value)
        child.wait_exit(deadline: PC::Wait::Deadline.after(50.milliseconds)).state.expired?.should be_true
        driver.signal(token, 0).should eq(Errno::EINVAL.value)
        driver.signal(token, 9).should eq(0)
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.signal.should eq(9)
        driver.signal(token, 15).should eq(Errno::ESRCH.value)
      ensure
        begin
          driver.release(port).should eq(0) if port != 0
        ensure
          Fixture::Darwin.collect(child)
        end
      end
    end
  end

  describe "Darwin existing-process exit observation" do
    {
      before_register: "register-watch",
      after_register:  "watch-identity",
    }.each do |phase, stage|
      it "refuses a reaped target at #{stage} and releases the native owners" do
        target = Process.new("/bin/sleep", ["30"])
        collected = false
        driver = Fixture::Darwin::Registration.new(phase) do
          target.signal(Signal::KILL)
          status = target.wait
          collected = true
          status.signal_exit?.should be_true
          nil
        end
        handle = nil.as(PC::Handle?)
        begin
          error = expect_raises(PC::Observation::Failed) do
            handle = PC::Internal::Darwin::Authority.acquire(target.pid,
              required: PC::Capability::Request.wait, driver: driver)
          end
          diagnostic = error.diagnostic.not_nil!
          diagnostic.stage.should eq(stage)
          diagnostic.native_domain.should eq("errno")
          diagnostic.native_code.should eq(Errno::ESRCH.value)
          collected.should be_true
          driver.queues.should eq(1)
          driver.ports.should eq(1)
        ensure
          handle.try(&.close)
          unless collected
            target.signal(Signal::KILL) unless target.terminated?
            target.wait
          end
        end
      end
    end

    it "observes a non-child exit without taking status from its reaper" do
      child = Fixture::Darwin.child
      handle = nil.as(PC::Handle?)
      begin
        # The Unix launcher delegates native parenthood to its helper.
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.wait)
        handle.identity.generation.not_nil!.domain.should eq("darwin.audit.pidversion")
        handle.capabilities.supports?(PC::Capability::Request.wait).should be_true
        handle.kill.disposition.should be_a(PC::Control::Refused)
        handle.wait_exit(deadline: PC::Wait::Deadline.after(20.milliseconds)).state.expired?.should be_true

        child.handle.kill.disposition.should be_a(PC::Control::Report::Success)
        result = handle.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        result.observation.identity.should eq(handle.identity)
        result.observation.termination.terminated?.should be_true
        child.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds)).info.not_nil!.signal.should eq(9)
      ensure
        handle.try(&.close)
        Fixture::Darwin.collect(child)
      end
    end

    it "keeps a duplicate's wait source after closing another view" do
      child = Fixture::Darwin.child
      handle = nil.as(PC::Handle?)
      copy = nil.as(PC::Handle?)
      begin
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.wait)
        copy = handle.duplicate(required: PC::Capability::Request.wait)
        cancel = PC::Wait::Cancellation.new
        cancel.cancel
        handle.wait_exit(cancel: cancel).state.cancelled?.should be_true
        handle.close.complete?.should be_true
        handle.wait_exit.state.closed?.should be_true
        copy.wait_exit(deadline: PC::Wait::Deadline.after(20.milliseconds)).state.expired?.should be_true

        child.handle.kill
        result = copy.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        # The same terminal evidence remains available after the one-shot event.
        copy.wait_exit.state.completed?.should be_true
        copy.observe.sampled_at.should eq(result.observation.sampled_at)
      ensure
        copy.try(&.close)
        handle.try(&.close)
        Fixture::Darwin.collect(child)
      end
    end

    it "binds a present zombie that exits between registration and identity sampling" do
      script = <<-SHELL
        exec 3<&0
        (read -r release <&3; exit 23) &
        target=$!
        printf '%s\n' "$target"
        kill -STOP "$$"
        wait "$target"
        SHELL
      holder = Process.new("/bin/sh", ["-c", script], input: Process::Redirect::Pipe, output: Process::Redirect::Pipe)
      handle = nil.as(PC::Handle?)
      collected = false
      begin
        holder.output.read_timeout = 5.seconds
        pid = holder.output.gets.not_nil!.to_i
        deadline = PC::Wait::Deadline.after(5.seconds)
        loop do
          output = IO::Memory.new
          Process.run("/bin/ps", ["-o", "state=", "-p", holder.pid.to_s], output: output)
          break if output.to_s.strip.starts_with?('T')
          raise "zombie fixture parent did not stop" if deadline.expired?
          deadline.pause
        end

        observation = nil.as(PC::Observation?)
        driver = Fixture::Darwin::Registration.new(:after_register) do
          holder.input.puts "exit"
          holder.input.close
          deadline = PC::Wait::Deadline.after(5.seconds)
          loop do
            observation = PC.observe(pid)
            break if observation.not_nil!.execution.zombie?
            raise "zombie fixture target did not exit" if deadline.expired?
            deadline.pause
          end
          nil
        end
        handle = PC::Internal::Darwin::Authority.acquire(pid,
          required: PC::Capability::Request.wait, driver: driver)
        result = handle.wait_exit(deadline: PC::Wait::Deadline.after(5.seconds))
        result.state.completed?.should be_true
        result.observation.identity.should eq(handle.identity)
        result.observation.termination.terminated?.should be_true
        observation.not_nil!.presence.present?.should be_true
        observation.not_nil!.termination.terminated?.should be_true
        observation.not_nil!.execution.zombie?.should be_true
        handle.close.complete?.should be_true
        driver.queues.should eq(1)
        driver.ports.should eq(1)
        holder.signal(Signal::CONT)
        status = holder.wait
        collected = true
        status.exit_code.should eq(23)
      ensure
        handle.try(&.close)
        unless collected
          holder.input.close unless holder.input.closed?
          holder.signal(Signal::KILL) unless holder.terminated?
          holder.wait
        end
      end
    end
  end
{% end %}
