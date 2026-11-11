require "./spec_helper"

{% if flag?(:linux) && !flag?(:android) && (flag?(:aarch64) || flag?(:x86_64)) %}
  module Fixture::Linux
    def self.require_pidfd(required : PC::Capability::Request) : Nil
      handle = PC::Platform::Linux.open(Process.pid, required: required)
      handle.close.complete?.should be_true
    rescue ex : PC::Error::Unsupported | PC::Error::Access::Denied
      raise ex if ENV["PROCESS_CONTROL_REQUIRE_PIDFD"]? == "1"
      pending! "#{ex.message} (#{ex.diagnostic.try(&.native_code)})"
    end

    def self.with_child(&)
      result = PC::Command.new("/bin/sleep", ["30"]).spawn(deadline: wait_budget)
      case result
      in PC::Spawn::Started
        child = result.child
      in PC::Spawn::Pending
        result.abort(deadline: wait_budget)
        raise "fixture launch remained pending"
      in PC::Spawn::Rejected
        raise result.error
      end
      begin
        yield child
      ensure
        child.handle.kill
        child.wait_exit(deadline: wait_budget)
        child.close
      end
    end

    def self.wait_budget
      PC::Wait::Deadline.after(5.seconds)
    end

    def self.expect_stopped(child : PC::Child, stopped : Bool) : Nil
      deadline = wait_budget
      loop do
        stat = File.read("/proc/#{child.identity.pid}/stat")
        state = stat[stat.rindex(')').not_nil! + 2]
        return if (state == 'T') == stopped
        raise "fixture did not reach expected stopped state" if deadline.expired?
        deadline.pause
      end
    end
  end

  describe "Linux retained process authority" do
    it "waits on a retained process without collecting its native child status" do
      Fixture::Linux.require_pidfd(PC::Capability::Request.wait)
      Fixture::Linux.with_child do |child|
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.wait)
        begin
          handle.capabilities.binding.retained?.should be_true
          observation = handle.observe
          observation.presence.present?.should be_true
          observation.termination.alive?.should be_true
          observation.execution.unknown?.should be_true
          handle.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
          cancel = PC::Wait::Cancellation.new
          cancel.cancel
          handle.wait_exit(cancel: cancel).state.cancelled?.should be_true
          child.handle.request_stop
          result = handle.wait_exit(deadline: Fixture::Linux.wait_budget)
          result.state.completed?.should be_true
          result.observation.termination.terminated?.should be_true
          child.wait_exit(deadline: Fixture::Linux.wait_budget).info.not_nil!.signal.should eq(::Signal::TERM.value)
          handle.observe.termination.terminated?.should be_true
        ensure
          handle.close
        end
      end
    end

    it "duplicates retained authority and delivers an arbitrary POSIX signal after the original closes" do
      Fixture::Linux.require_pidfd(PC::Capability::Request.control)
      Fixture::Linux.with_child do |child|
        required = PC::Capability::Request.new([PC::Capability::Operation.new("control.signal")], :retained)
        handle = PC::Handle.open(child.identity.pid, required: required)
        copy = nil.as(PC::Handle?)
        begin
          copy = handle.duplicate(required: required)
          handle.close.complete?.should be_true
          handle.kill.disposition.should be_a(PC::Control::Refused)
          copy.identity.should eq(handle.identity)
          copy.signal(PC::Control::Signal.new("posix", ::Signal::USR1.value)).disposition.should be_a(PC::Control::Report::Success)
          child.wait_exit(deadline: Fixture::Linux.wait_budget).info.not_nil!.signal.should eq(::Signal::USR1.value)
          copy.wait_exit(deadline: Fixture::Linux.wait_budget).state.completed?.should be_true
          failure = copy.kill.disposition.as(PC::Control::Report::Failure)
          failure.diagnostic.native_code.should eq(Errno::ESRCH.value)
          copy.close.complete?.should be_true
        ensure
          copy.try(&.close)
          handle.close
        end
      end
    end

    it "sends POSIX stop and continue to the retained target" do
      Fixture::Linux.require_pidfd(PC::Capability::Request.control)
      Fixture::Linux.with_child do |child|
        handle = PC::Handle.open(child.identity.pid, required: PC::Capability::Request.control)
        begin
          handle.suspend.disposition.should be_a(PC::Control::Report::Success)
          Fixture::Linux.expect_stopped(child, true)
          handle.resume.disposition.should be_a(PC::Control::Report::Success)
          Fixture::Linux.expect_stopped(child, false)
          handle.kill.disposition.should be_a(PC::Control::Report::Success)
          child.wait_exit(deadline: Fixture::Linux.wait_budget).info.not_nil!.signal.should eq(::Signal::KILL.value)
        ensure
          handle.close
        end
      end
    end

    it "rejects an unverified generation before opening a retained handle" do
      expected = PC::Identity.new(Process.pid, generation: PC::Identity::Generation.new("unavailable", "expected"))
      expect_raises(PC::Identity::Unverifiable) do
        PC::Handle.open(Process.pid, required: PC::Capability::Request.wait, expected: expected)
      end
    end

    it "does not treat a checked binding request as a retained binding request" do
      required = PC::Capability::Request.new([PC::Capability::Operation.new("control.kill")], :checked)
      expect_raises(PC::Error::Unsupported) { PC::Handle.open(Process.pid, required: required) }
    end

    it "keeps non-native requests distinct from an attempted Linux syscall failure" do
      Fixture::Linux.require_pidfd(PC::Capability::Request.control)
      handle = PC::Handle.open(Process.pid, required: PC::Capability::Request.control)
      begin
        handle.signal(PC::Control::Signal.new("windows", 9)).disposition.should be_a(PC::Control::Refused)
        handle.kill(PC::Control::Kill::Request.new(42_u32)).disposition.should be_a(PC::Control::Refused)
        failure = handle.signal(PC::Control::Signal.new("posix", Int32::MAX)).disposition.as(PC::Control::Report::Failure)
        failure.diagnostic.native_code.should eq(Errno::EINVAL.value)
      ensure
        handle.close
      end
    end
  end
{% end %}
