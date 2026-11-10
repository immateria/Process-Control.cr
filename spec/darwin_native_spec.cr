require "./spec_helper"

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
{% end %}
