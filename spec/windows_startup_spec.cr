require "./spec_helper"

{% if flag?(:windows) %}
  require "random/secure"
  require "./support/windows/startup"

  private def startup_launch(driver : Fixture::Windows::Startup, marker : String) : PC::Spawn::Attempt::Result
    command = PC::Command.new(Process.executable_path.not_nil!, [marker])
      .with_env({"PROCESS_CONTROL_WINDOWS_FIXTURE" => "startup-marker"})
    profile = PC::Internal::Windows::Authority.profile(terminate: true)
    PC::Internal::Windows::Work.new(command.prepare, profile, driver: driver)
      .launch(deadline: PC::Wait::Deadline.after(5.seconds), cancel: nil)
  end

  private def startup_rejection(attempt : PC::Spawn::Attempt::Result) : PC::Spawn::Rejected
    case attempt
    when PC::Spawn::Attempt::Rejected
      attempt.result
    when PC::Spawn::Attempt::Pending
      attempt.owner.resolve(deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Rejected)
    else
      raise "failed startup unexpectedly registered a child"
    end
  end

  describe "Windows startup failure ownership" do
    {identify: "GetProcessTimes", duplicate: "DuplicateHandle", resume: "ResumeThread"}.each do |boundary, operation|
      it "collects failed #{operation} setup without executing the suspended workload" do
        marker = File.join(Dir.tempdir, "process-control-startup-#{Random::Secure.hex(12)}")
        driver = Fixture::Windows::Startup.new(boundary)
        before = Fixture::Windows.handle_count
        begin
          result = startup_rejection(startup_launch(driver, marker))
          result.attempted.should be_true
          result.cleanup.complete?.should be_true
          detail = result.error.diagnostic.not_nil!
          detail.operation.should eq(operation)
          detail.native_domain.should eq("win32")
          detail.native_code.should eq(WinError::ERROR_ACCESS_DENIED.value)
          File.exists?(marker).should be_false
          driver.alive?.should be_false
          driver.calls[:close_thread].should eq(1)
          driver.calls[:close_process].should eq(1)
          driver.calls[:close_control].should eq(boundary == :resume ? 1 : 0)
        ensure
          driver.dispose
          File.delete(marker) if File.exists?(marker)
        end
        Fixture::Windows.handle_count.should eq(before)
      end
    end

    it "retains a live suspended process after termination fails and settles after independent cleanup" do
      marker = File.join(Dir.tempdir, "process-control-startup-#{Random::Secure.hex(12)}")
      driver = Fixture::Windows::Startup.new(:terminate)
      before = Fixture::Windows.handle_count
      begin
        attempt = startup_launch(driver, marker).as(PC::Spawn::Attempt::Pending)
        attempt.wait?.should be_false
        pending = attempt.owner
        pending.diagnostic.operation.should eq("TerminateProcess(startup cleanup)")
        pending.diagnostic.native_code.should eq(WinError::ERROR_ACCESS_DENIED.value)
        driver.alive?.should be_true
        pending.resolve(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
        pending.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
        expect_raises(PC::Error::Ownership) { pending.close }
        pending.cleanup_result.not_nil!.state.retryable?.should be_true
        driver.calls[:terminate].should eq(1)
        File.exists?(marker).should be_false
        driver.terminate_fixture
        result = pending.resolve(deadline: PC::Wait::Deadline.after(5.seconds)).as(PC::Spawn::Rejected)
        result.cleanup.complete?.should be_true
        result.error.diagnostic.not_nil!.operation.should eq("GetProcessTimes")
        driver.calls[:terminate].should eq(1)
        driver.calls[:close_process].should eq(1)
        pending.close.complete?.should be_true
      ensure
        driver.dispose
        File.delete(marker) if File.exists?(marker)
      end
      Fixture::Windows.handle_count.should eq(before)
    end

    it "keeps failed cleanup observation uncertain without closing or claiming a rejected launch" do
      marker = File.join(Dir.tempdir, "process-control-startup-#{Random::Secure.hex(12)}")
      driver = Fixture::Windows::Startup.new(:wait)
      before = Fixture::Windows.handle_count
      begin
        pending = startup_launch(driver, marker).as(PC::Spawn::Attempt::Pending).owner
        deadline = PC::Wait::Deadline.after(5.seconds)
        until pending.cleanup_result.not_nil!.state.uncertain?
          raise "cleanup did not observe the injected wait failure" if deadline.expired?
          deadline.pause
        end
        pending.diagnostic.operation.should eq("WaitForSingleObject(startup cleanup)")
        pending.diagnostic.native_code.should eq(WinError::ERROR_ACCESS_DENIED.value)
        pending.cleanup_result.not_nil!.records.last.state.uncertain?.should be_true
        pending.resolve(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
        expect_raises(PC::Error::Ownership) { pending.close }
        driver.calls[:close_process].should eq(0)
        driver.calls[:terminate].should eq(1)
        File.exists?(marker).should be_false
      ensure
        driver.dispose
        File.delete(marker) if File.exists?(marker)
      end
      Fixture::Windows.handle_count.should eq(before)
    end

    it "preserves uncertainty after a close side effect and never repeats that close" do
      marker = File.join(Dir.tempdir, "process-control-startup-#{Random::Secure.hex(12)}")
      driver = Fixture::Windows::Startup.new(:close)
      before = Fixture::Windows.handle_count
      begin
        pending = startup_launch(driver, marker).as(PC::Spawn::Attempt::Pending).owner
        deadline = PC::Wait::Deadline.after(5.seconds)
        until driver.calls[:close_process] == 1
          raise "startup process was not collected" if deadline.expired?
          deadline.pause
        end
        pending.cleanup_result.not_nil!.state.uncertain?.should be_true
        thread = pending.cleanup_result.not_nil!.records.find { |record| record.resource == "Windows primary thread" }.not_nil!
        thread.state.uncertain?.should be_true
        thread.diagnostic.not_nil!.operation.should eq("CloseHandle")
        pending.resolve(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
        pending.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
        expect_raises(PC::Error::Ownership) { pending.close }
        driver.calls[:close_thread].should eq(1)
        driver.calls[:close_control].should eq(1)
        driver.calls[:close_process].should eq(1)
        driver.alive?.should be_false
      ensure
        driver.dispose
        File.delete(marker) if File.exists?(marker)
      end
      Fixture::Windows.handle_count.should eq(before)
    end
  end
{% end %}
