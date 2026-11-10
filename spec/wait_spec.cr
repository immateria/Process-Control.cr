require "./spec_helper"

describe PC::Wait do
  it "uses monotonic deadlines and independent cancellation sources" do
    PC::Wait::Deadline.none.remaining.should be_nil
    PC::Wait::Deadline.after(Time::Span.zero).expired?.should be_true
    expect_raises(ArgumentError) { PC::Wait::Deadline.after(-1.second) }
    first = PC::Wait::Cancellation.new
    second = PC::Wait::Cancellation.new
    first.cancel
    first.cancel
    first.cancelled?.should be_true
    second.cancelled?.should be_false
  end

  it "preserves native POSIX signal evidence and distinguishes a shell convention" do
    normal = PC::Wait::Exit::Info.posix(143 << 8)
    normal.reason.exited?.should be_true
    normal.code.should eq(143_u32)
    normal.signal.should be_nil
    signaled = PC::Wait::Exit::Info.posix(15)
    signaled.reason.signaled?.should be_true
    signaled.signal.should eq(15)
    signaled.code.should be_nil
  end

  it "fans out one cached status independently of waiter timeout" do
    source = PC::Spawn::Status::Source.new(PC::Identity.new(123))
    source.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.expired?.should be_true
    source.publish(PC::Wait::Exit::Info.posix(7 << 8))
    3.times do
      result = source.wait_exit
      result.state.completed?.should be_true
      result.info.not_nil!.code.should eq(7_u32)
    end
    expect_raises(PC::Error::Ownership) { source.publish(PC::Wait::Exit::Info.posix(0)) }
  end

  it "retains collection failure without inventing status" do
    source = PC::Spawn::Status::Source.new(PC::Identity.new(123))
    source.fail(PC::Wait::Collection::Failed.new("transport lost"), termination: :unknown)
    result = source.wait_exit
    result.state.failed?.should be_true
    result.info.should be_nil
    result.failure.not_nil!.error.should be_a(PC::Wait::Collection::Failed)
  end
end
