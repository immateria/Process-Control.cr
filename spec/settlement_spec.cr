require "./group_spec"

describe "settlement callbacks" do
  it "settles every launch subscriber and group admission when earlier subscribers raise" do
    controller = Fixture::Controller.new
    group = PC::Group.new(controller)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "waiting"))
    calls = [] of Int32
    pending.on_settle do
      calls << 1
      raise "first callback"
    end
    pending.on_settle do
      calls << 2
      raise "second callback"
    end
    group.admit_spawn { pending }
    pending.on_settle { calls << 3 }

    pending.publish(PC::Spawn::Rejected.new(PC::Error.new("creation refused")))

    calls.should eq([1, 2, 3])
    pending.callback_failures.map(&.message).should eq(["first callback", "second callback"])
    pending.callback_failures.each { |failure| failure.stage.should eq("callback") }
    pending.callback_failures.clear
    pending.callback_failures.size.should eq(2)
    group.pending_launches.should be_empty
    group.shutdown(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.completed?.should be_true
    group.close.complete?.should be_true
    controller.releases.should eq(1)
    pending.close.complete?.should be_true
    calls.should eq([1, 2, 3])
  end

  it "preserves an offered child and its streams when notification fails" do
    authority = Fixture::Authority.new
    input, output = IO.pipe
    streams = PC::Stream::Endpoints.new(output: PC::Stream::Endpoint.new(input))
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source, streams)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "waiting"))
    pending.on_settle { raise "subscriber failed" }
    begin
      pending.publish(PC::Spawn::Started.new(child))
      pending.resolve.as(PC::Spawn::Started).child.should be(child)
      expect_raises(PC::Error::Ownership) { pending.resolve }
      output.puts "still owned"
      input.gets.should eq("still owned")
      pending.callback_failures.size.should eq(1)
      authority.target.releases.should eq(0)
    ensure
      authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
      child.close
      output.close
    end
  end

  it "completes abort settlement even when a queued subscriber raises" do
    controller = Fixture::Controller.new
    group = PC::Group.new(controller)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "waiting"))
    calls = 0
    pending.on_settle { raise "abort subscriber failed" }
    group.admit_spawn { pending }
    pending.on_settle { calls += 1 }
    pending.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
    pending.publish_abort(PC::Spawn::Rejected.new(PC::Error.new("aborted"), attempted: true))
    pending.resolve.should be_a(PC::Spawn::Rejected)
    calls.should eq(1)
    pending.callback_failures.size.should eq(1)
    group.pending_launches.should be_empty
    group.close.complete?.should be_true
    controller.releases.should eq(1)
  end

  it "releases admitted control owners when an earlier subscriber raises" do
    authority = Fixture::Authority.new
    request = PC::Control::Kill::Request.new
    pending = PC::Control::Pending.new(request, authority.identity, "fixture")
    pending.on_settle { raise "control subscriber failed" }
    authority.target.pending = pending
    handle = PC::Handle.new(authority)
    controller = Fixture::Controller.new
    controller.pending = pending
    group = PC::Group.new(controller)
    handle.kill
    group.kill
    handle.close.state.retryable?.should be_true
    group.close.state.retryable?.should be_true

    pending.publish(PC::Control::Result.new(request, authority.identity, PC::Control::Report::Success.new("accepted")))

    pending.wait.disposition.should be_a(PC::Control::Report::Success)
    pending.callback_failures.map(&.message).should eq(["control subscriber failed"])
    handle.retry_cleanup.complete?.should be_true
    group.retry_cleanup.complete?.should be_true
    authority.target.releases.should eq(1)
    controller.releases.should eq(1)
  end

  it "records errors from subscribers registered after settlement without replaying old callbacks" do
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "waiting"))
    calls = 0
    pending.on_settle { calls += 1 }
    pending.publish(PC::Spawn::Rejected.new(PC::Error.new("refused")))
    pending.on_settle { raise "late subscriber failed" }
    pending.on_settle { calls += 1 }
    calls.should eq(2)
    pending.callback_failures.map(&.message).should eq(["late subscriber failed"])

    request = PC::Control::Kill::Request.new
    control = PC::Control::Pending.new(request, PC::Identity.new(123), "fixture")
    control.publish(PC::Control::Result.new(request, PC::Identity.new(123), PC::Control::Report::Success.new("accepted")))
    control.on_settle { raise "late control subscriber failed" }
    control.on_settle { calls += 1 }
    calls.should eq(3)
    control.callback_failures.map(&.message).should eq(["late control subscriber failed"])
  end
end
