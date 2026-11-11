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
      driver.references.should eq(0)
    end

    it "refuses the watcher if the PID generation changed during registration" do
      driver = Fixture::Darwin::Driver.new
      driver.watch_version = 8_u32
      expect_raises(PC::Identity::Mismatch) { driver.acquire(required: PC::Capability::Request.wait) }
      driver.references.should eq(0)
      driver.watch_closes.should eq(1)
      driver.watch_polls.should eq(0)
    end

    it "treats ESRCH during registration as a failed acquisition" do
      driver = Fixture::Darwin::Driver.new
      diagnostic = PC::Diagnostic.new("handle.open", "kevent registration failed", native_domain: "errno",
        native_code: Errno::ESRCH.value.to_i64, stage: "register-watch")
      driver.registration_error = PC::Observation::Failed.new("watch registration failed", diagnostic)
      error = expect_raises(PC::Observation::Failed) { driver.acquire(required: PC::Capability::Request.wait) }
      error.diagnostic.not_nil!.native_code.should eq(Errno::ESRCH.value)
      driver.references.should eq(0)
      driver.watch_closes.should eq(1)
    end

    it "consumes a one-shot exit event once across duplicates" do
      driver = Fixture::Darwin::Driver.new
      driver.available = false
      handle = driver.acquire(required: PC::Capability::Request.wait)
      copy = nil.as(PC::Handle?)
      begin
        copy = handle.duplicate(required: PC::Capability::Request.wait)
        first = handle.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero))
        second = copy.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero))
        first.state.completed?.should be_true
        second.observation.should eq(first.observation)
        driver.watch_polls.should eq(1)
        handle.close.complete?.should be_true
        driver.watch_closes.should eq(0)
      ensure
        copy.try(&.close)
        handle.close
      end
      driver.watch_closes.should eq(1)
    end

    it "wakes a pending local wait as closed when its handle closes" do
      driver = Fixture::Darwin::Driver.new
      driver.watch_exited = false
      handle = driver.acquire(required: PC::Capability::Request.wait)
      result = Channel(PC::Wait::Exit::Result).new(1)
      deadline = PC::Wait::Deadline.after(5.seconds)
      spawn { result.send(handle.wait_exit(deadline: deadline)) }
      begin
        until driver.watch_polls > 0
          raise "wait did not sample its source" if deadline.expired?
          deadline.pause
        end
        handle.close.complete?.should be_true
        select
        when receipt = result.receive
          receipt.state.closed?.should be_true
          receipt.observation.termination.unknown?.should be_true
        when timeout(5.seconds)
          fail "closed handle did not settle its wait"
        end
      ensure
        handle.close
      end
    end

    it "records an uncertain queue close and releases the Mach reference" do
      driver = Fixture::Darwin::Driver.new
      driver.watch_close_code = Errno::EINTR.value
      handle = driver.acquire(required: PC::Capability::Request.wait)
      result = handle.close
      result.state.uncertain?.should be_true
      record = result.records.first
      record.resource.should eq("Darwin exit watch")
      record.diagnostic.not_nil!.native_code.should eq(Errno::EINTR.value)
      handle.retry_cleanup.state.uncertain?.should be_true
      driver.watch_closes.should eq(1)
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
