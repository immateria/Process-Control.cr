require "./support/authority"

describe PC::Handle do
  it "keeps a cleanup owner when duplicate validation fails after acquisition" do
    authority = Fixture::Duplicating.new
    handle = PC::Handle.new(authority)
    begin
      error = expect_raises(PC::Handle::Acquisition::Failed) do
        handle.duplicate(required: PC::Capability::Request.control)
      end
      error.owner.closed?.should be_true
      error.owner.release_result.not_nil!.state.retryable?.should be_true
      error.owner.retry_cleanup.complete?.should be_true
      authority.target.releases.should eq(2)
    ensure
      handle.close
    end
  end

  it "retries an eligible participant without replaying an uncertain close" do
    authority = Fixture::Mixed.new
    handle = PC::Handle.new(authority)
    handle.close.state.uncertain?.should be_true
    retried = handle.retry_cleanup
    retried.state.uncertain?.should be_true
    retried.records[1].state.complete?.should be_true
    authority.retries.should eq(1)
    authority.target.releases.should eq(1)
    handle.retry_cleanup.records[1].state.complete?.should be_true
    authority.retries.should eq(1)
  end

  it "permits one immediate control attempt with a zero budget" do
    authority = Fixture::Authority.new
    handle = PC::Handle.new(authority)
    begin
      handle.kill(deadline: PC::Wait::Deadline.after(Time::Span.zero)).disposition.should be_a(PC::Control::Report::Success)
      authority.target.calls.should eq(1)
    ensure
      handle.close
    end
  end

  it "keeps duplicated owners independent and refuses control after close" do
    authority = Fixture::Authority.new
    handle = PC::Handle.new(authority)
    duplicate = handle.duplicate(required: PC::Capability::Request.control)
    handle.close.complete?.should be_true
    handle.close.complete?.should be_true
    handle.kill.disposition.should be_a(PC::Control::Refused)
    duplicate.kill.disposition.should be_a(PC::Control::Report::Success)
    authority.target.calls.should eq(1)
    authority.target.releases.should eq(1)
    duplicate.close
    authority.target.releases.should eq(2)
    handle.wait_exit.state.closed?.should be_true
  end

  it "retains an admitted operation's authority until its receipt settles" do
    authority = Fixture::Authority.new
    request = PC::Control::Kill::Request.new
    pending = PC::Control::Pending.new(request, authority.identity, "fixture")
    authority.target.pending = pending
    handle = PC::Handle.new(authority)
    handle.kill.disposition.should be_a(PC::Control::Delivery::Unknown)
    handle.close.state.retryable?.should be_true
    authority.target.releases.should eq(0)
    pending.publish(PC::Control::Result.new(request, authority.identity, PC::Control::Report::Success.new("accepted")))
    handle.retry_cleanup.complete?.should be_true
    authority.target.releases.should eq(1)
  end
end

describe PC::Child do
  it "replaces a provider's retryable release records after successful retry" do
    authority = Fixture::Retrying.new
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source)
    authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
    child.close.state.retryable?.should be_true
    child.retry_cleanup.complete?.should be_true
    authority.target.releases.should eq(2)
  end

  it "preserves status collection across release of streams and control" do
    authority = Fixture::Authority.new
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source)
    child.handle.responds_to?(:close).should be_false
    child.close
    authority.target.source.publish(PC::Wait::Exit::Info.posix(42 << 8))
    child.wait_exit.info.not_nil!.code.should eq(42_u32)
    child.wait_exit.info.not_nil!.code.should eq(42_u32)
    child.handle.kill.disposition.should be_a(PC::Control::Refused)
  end
end
