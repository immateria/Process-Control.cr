require "./support/authority"

describe PC::Command do
  it "copies arguments and returns a new command for environment and cwd edits" do
    args = ["first"]
    env = {"MARK" => "before".as(String?)}
    original = PC::Command.new("/bin/echo", args)
    changed = original.with_env(env, inherit: false).with_cwd("/tmp")
    args << "later"
    env["MARK"] = "after"
    original.args.should eq(["first"])
    original.args.clear
    original.args.should eq(["first"])
    original.cwd.should be_nil
    changed.cwd.should eq("/tmp")
    changed.environment.resolve["MARK"].should eq("before")
    expect_raises(ArgumentError) { PC::Command.new("bad\0path") }
    expect_raises(ArgumentError) { original.with_env({"bad=name" => "value".as(String?)}) }
  end
end

describe PC::Spawn::Pending do
  it "transfers an owning child once and does not cancel work on a timed wait" do
    authority = Fixture::Authority.new
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "awaiting registration"))
    pending.resolve(deadline: PC::Wait::Deadline.after(Time::Span.zero)).as(PC::Spawn::Pending).should be(pending)
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source)
    pending.publish(PC::Spawn::Started.new(child))
    pending.resolve.should be_a(PC::Spawn::Started)
    expect_raises(PC::Error::Ownership) { pending.resolve }
    authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
    child.close
  end
end

describe PC::Spawn::Registration do
  it "can abort an invalid handoff without replaying target control" do
    authority = Fixture::Authority.new
    other = PC::Spawn::Status::Source.new(PC::Identity.new(456))
    pending = PC::Spawn::Registration.new(authority, other).publish.as(PC::Spawn::Pending)
    pending.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero))
    budget = PC::Wait::Deadline.after(1.second)
    until authority.target.calls == 1
      fail "abort never reached the owned authority" if budget.expired?
      budget.pause
    end
    pending.abort(deadline: PC::Wait::Deadline.after(Time::Span.zero))
    authority.target.calls.should eq(1)
    authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
    other.publish(PC::Wait::Exit::Info.posix(0))
    result = pending.resolve(deadline: PC::Wait::Deadline.after(1.second))
    result.should be_a(PC::Spawn::Rejected)
    authority.target.releases.should eq(1)
    pending.close.complete?.should be_true
  end

  it "retains a rejected handoff when target cleanup cannot be proved" do
    authority = Fixture::Authority.new
    wrong = PC::Spawn::Status::Source.new(PC::Identity.new(456))
    registration = PC::Spawn::Registration.new(authority, wrong)
    result = registration.publish
    result.should be_a(PC::Spawn::Pending)
    authority.target.releases.should eq(0)
    expect_raises(PC::Error::Ownership) { result.as(PC::Spawn::Pending).close }
  end

  it "consumes registration exactly once" do
    authority = Fixture::Authority.new
    registration = PC::Spawn::Registration.new(authority, authority.target.source)
    result = registration.publish
    result.should be_a(PC::Spawn::Started)
    expect_raises(PC::Error::Ownership) { registration.publish }
    authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
    result.as(PC::Spawn::Started).child.close
  end
end
