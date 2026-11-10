require "./spec_helper"
require "./support/darwin"

{% if flag?(:darwin) %}
  describe "Darwin checked authority" do
    it "refuses unavailable and incompatible profiles before owning a reference" do
      driver = Fixture::Darwin::Driver.new
      driver.available = false
      expect_raises(PC::Error::Unsupported) { driver.acquire }
      driver.references.should eq(0)
      driver.available = true
      retained = PC::Capability::Request.new([PC::Capability::Operation.new("control.kill")], :retained)
      expect_raises(PC::Error::Unsupported) { driver.acquire(required: retained) }
      expect_raises(PC::Error::Unsupported) { driver.acquire(required: PC::Capability::Request.wait) }
      driver.references.should eq(0)
    end

    it "returns acquisition errors with Mach provenance" do
      driver = Fixture::Darwin::Driver.new
      driver.open_code = 5
      error = expect_raises(PC::Observation::Failed) { driver.acquire }
      error.diagnostic.not_nil!.native_domain.should eq("kern_return_t")
      error.diagnostic.not_nil!.native_code.should eq(5)
      driver.references.should eq(0)
    end

    it "releases a partial acquisition after token capture fails" do
      driver = Fixture::Darwin::Driver.new
      driver.read_code = 4
      error = expect_raises(PC::Observation::Failed) { driver.acquire }
      error.diagnostic.not_nil!.stage.should eq("audit-token")
      driver.references.should eq(0)
      driver.releases.should eq(1)
    end

    it "preserves an owning failure when partial-acquisition release is uncertain" do
      driver = Fixture::Darwin::Driver.new
      driver.read_code = 4
      driver.release_code = 5
      error = expect_raises(PC::Handle::Acquisition::Failed) { driver.acquire }
      error.failure.should be_a(PC::Observation::Failed)
      error.owner.closed?.should be_true
      error.owner.release_result.not_nil!.state.uncertain?.should be_true
      error.owner.retry_cleanup.state.uncertain?.should be_true
      driver.releases.should eq(1)
    end

    it "rejects malformed token counts and conflicting PIDs without leaking" do
      driver = Fixture::Darwin::Driver.new
      driver.count = 7
      expect_raises(PC::Identity::Unverifiable) { driver.acquire }
      driver.references.should eq(0)
      driver.count = 8
      driver.pid = 124
      expect_raises(PC::Identity::Mismatch) { driver.acquire }
      driver.references.should eq(0)
    end

    it "validates expected identity against the acquired token" do
      driver = Fixture::Darwin::Driver.new
      wrong = PC::Identity.new(123, generation: PC::Identity::Generation.new("darwin.audit.pidversion", "8"))
      expect_raises(PC::Identity::Mismatch) { driver.acquire(expected: wrong) }
      driver.references.should eq(0)
      unknown = PC::Identity.new(123, generation: PC::Identity::Generation.new("another-domain", "7"))
      expect_raises(PC::Identity::Unverifiable) { driver.acquire(expected: unknown) }
      driver.references.should eq(0)
    end

    it "keeps independent duplicate rights without reacquiring a PID" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      copy = handle.duplicate(required: PC::Capability::Request.control)
      begin
        driver.references.should eq(2)
        driver.reads.should eq(1)
        handle.close.complete?.should be_true
        driver.references.should eq(1)
        copy.kill.disposition.should be_a(PC::Control::Report::Success)
        driver.signals.should eq([{123_u32, 7_u32, 9}])
        copy.identity.should eq(handle.identity)
      ensure
        handle.close
        copy.close
      end
      driver.references.should eq(0)
      driver.releases.should eq(2)
    end

    it "reports direct positive errno values from attempted signals" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      begin
        driver.signal_code = 3
        Errno.value = Errno::EACCES
        result = handle.kill
        failure = result.disposition.as(PC::Control::Report::Failure)
        failure.diagnostic.native_domain.should eq("errno")
        failure.diagnostic.native_code.should eq(3)
        failure.diagnostic.stage.should eq("signal")
        result.postcondition.skipped?.should be_true
      ensure
        handle.close
      end
    end

    it "does not interpret an acquired reference in a changed process context" do
      driver = Fixture::Darwin::Driver.new
      driver.open_context = 1001_i64
      error = expect_raises(PC::Handle::Acquisition::Failed) { driver.acquire }
      error.failure.should be_a(PC::Error::Context::Mismatch)
      error.owner.release_result.not_nil!.state.retryable?.should be_true
      driver.reads.should eq(0)
      driver.references.should eq(1)
      driver.context = 1000
      error.owner.retry_cleanup.complete?.should be_true
      driver.references.should eq(0)
    end

    it "retains cleanup ownership when its release budget ends before I/O" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      cancel = PC::Wait::Cancellation.new
      cancel.cancel
      handle.close(cancel: cancel).state.retryable?.should be_true
      driver.references.should eq(1)
      driver.releases.should eq(0)
      handle.retry_cleanup.complete?.should be_true
      driver.references.should eq(0)
    end

    it "uses explicit POSIX signal semantics and refuses foreign parameters" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      begin
        handle.request_stop
        handle.suspend
        handle.resume
        driver.signals.map(&.[2]).should eq([15, 17, 19])
        handle.kill(PC::Control::Kill::Request.new(exit_code: 1_u32)).disposition.should be_a(PC::Control::Refused)
        handle.signal(PC::Control::Signal.new("windows", 1)).disposition.should be_a(PC::Control::Refused)
        handle.signal(PC::Control::Signal.new("posix", 32)).disposition.should be_a(PC::Control::Refused)
        driver.signals.size.should eq(3)
        handle.wait_exit.state.failed?.should be_true
      ensure
        handle.close
      end
    end

    it "does not deliver after cancellation or an expired admission budget" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      begin
        cancel = PC::Wait::Cancellation.new
        cancel.cancel
        handle.kill(cancel: cancel).disposition.should be_a(PC::Control::Refused)
        expired = PC::Wait::Deadline.new(PC::Clock.now - 1.second)
        handle.kill(deadline: expired).disposition.should be_a(PC::Control::Refused)
        driver.signals.should be_empty
      ensure
        handle.close
      end
    end

    it "does not infer death from a failed Mach observation" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      begin
        driver.read_code = 4
        observation = handle.observe
        observation.presence.unknown?.should be_true
        observation.termination.unknown?.should be_true
        observation.identity.should eq(handle.identity)
        observation.diagnostic.not_nil!.native_code.should eq(4)
      ensure
        handle.close
      end
    end

    it "does not operate in another process context and can release back in its owner" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      driver.context = 1001
      result = handle.kill.disposition.as(PC::Control::Refused)
      result.reason.should be_a(PC::Error::Context::Mismatch)
      expect_raises(PC::Error::Context::Mismatch) { handle.observe }
      expect_raises(PC::Error::Context::Mismatch) { handle.duplicate }
      handle.close.state.retryable?.should be_true
      driver.references.should eq(1)
      driver.signals.should be_empty
      driver.context = 1000
      handle.retry_cleanup.complete?.should be_true
      driver.references.should eq(0)
    end

    it "does not replay an uncertain native release" do
      driver = Fixture::Darwin::Driver.new
      handle = driver.acquire
      driver.release_code = 5
      handle.close.state.uncertain?.should be_true
      handle.retry_cleanup.state.uncertain?.should be_true
      driver.releases.should eq(1)
      handle.kill.disposition.should be_a(PC::Control::Refused)
      driver.signals.should be_empty
    end
  end
{% end %}
