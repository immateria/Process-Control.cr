require "./group_spec"

module Fixture::Settlement
  def self.receive(channel : Channel(T)) : T forall T
    select
    when value = channel.receive
      value
    when timeout(2.seconds)
      raise "timed out waiting for settlement fixture"
    end
  end

  def self.immediate : PC::Wait::Deadline
    PC::Wait::Deadline.after(Time::Span.zero)
  end
end

describe "gated launch publication and shutdown" do
  it "hides a published child while abort is admitted and retains group authority through cleanup" do
    authority = Fixture::Authority.new
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source)
    controller = Fixture::Controller.new
    group = PC::Group.new(controller)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "fixture"))
    abort_entered = Channel(Nil).new(1)
    allow_abort = Channel(Nil).new(1)
    abort_done = Channel(PC::Spawn::Result).new(1)
    pending.on_abort do |_, _|
      abort_entered.send(nil)
      Fixture::Settlement.receive(allow_abort)
      child.handle.kill
      authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
      cleanup = child.close
      rejection = PC::Spawn::Rejected.new(PC::Error.new("aborted and collected"), cleanup, attempted: true)
      pending.publish_abort(rejection)
      rejection
    end
    group.admit_spawn { pending }.as(PC::Spawn::Pending).should be(pending)
    spawn { abort_done.send(pending.abort) }
    Fixture::Settlement.receive(abort_entered)
    begin
      pending.publish(PC::Spawn::Started.new(child))
      pending.resolve(deadline: Fixture::Settlement.immediate).as(PC::Spawn::Pending).should be(pending)
      expect_raises(PC::Error::Ownership) { pending.close }
      shutdown = group.shutdown(deadline: Fixture::Settlement.immediate)
      shutdown.state.expired?.should be_true
      shutdown.drain.inflight.should eq(1)
      group.pending_launches.should eq([pending])
      group.admit_spawn { fail "admission reopened" }.should be_a(PC::Spawn::Rejected)
      group.close.state.retryable?.should be_true
      controller.releases.should eq(0)
    ensure
      allow_abort.send(nil)
    end
    Fixture::Settlement.receive(abort_done).should be_a(PC::Spawn::Rejected)
    pending.resolve(deadline: Fixture::Settlement.immediate).should be_a(PC::Spawn::Rejected)
    pending.close.complete?.should be_true
    authority.target.calls.should eq(1)
    authority.target.releases.should eq(1)
    group.pending_launches.should be_empty
    group.retry_cleanup.complete?.should be_true
    group.retry_cleanup.complete?.should be_true
    controller.releases.should eq(1)
  end

  it "transfers a child exactly once and retains the group until its settlement callback runs" do
    authority = Fixture::Authority.new
    child = PC::Child.new(PC::Handle.new(authority), authority.target.source)
    controller = Fixture::Controller.new
    group = PC::Group.new(controller)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "fixture"))
    publication_entered = Channel(Nil).new(1)
    allow_settlement = Channel(Nil).new(1)
    publication_done = Channel(Nil).new(1)
    pending.on_settle do
      publication_entered.send(nil)
      Fixture::Settlement.receive(allow_settlement)
    end
    pending.on_abort { |_, _| raise "abort provider ran after transfer" }
    group.admit_spawn { pending }.as(PC::Spawn::Pending).should be(pending)
    spawn do
      pending.publish(PC::Spawn::Started.new(child))
      publication_done.send(nil)
    end
    Fixture::Settlement.receive(publication_entered)
    begin
      competitors = Channel(Symbol).new(2)
      transferred = Channel(PC::Child).new(1)
      2.times do
        spawn do
          begin
            result = pending.resolve(deadline: Fixture::Settlement.immediate)
            if result.is_a?(PC::Spawn::Started)
              transferred.send(result.child)
              competitors.send(:started)
            else
              competitors.send(:unsettled)
            end
          rescue PC::Error::Ownership
            competitors.send(:ownership)
          end
        end
      end
      outcomes = [Fixture::Settlement.receive(competitors), Fixture::Settlement.receive(competitors)]
      outcomes.count(:started).should eq(1)
      outcomes.count(:ownership).should eq(1)
      Fixture::Settlement.receive(transferred).should be(child)
      expect_raises(PC::Error::Ownership) { pending.abort(deadline: Fixture::Settlement.immediate) }
      expect_raises(PC::Error::Ownership) { pending.close }
      shutdown = group.shutdown(deadline: Fixture::Settlement.immediate)
      shutdown.state.expired?.should be_true
      shutdown.drain.inflight.should eq(1)
      group.close.state.retryable?.should be_true
      controller.releases.should eq(0)
    ensure
      allow_settlement.send(nil)
    end
    Fixture::Settlement.receive(publication_done)
    group.pending_launches.should be_empty
    group.retry_cleanup.complete?.should be_true
    group.retry_cleanup.complete?.should be_true
    controller.releases.should eq(1)
    authority.target.source.publish(PC::Wait::Exit::Info.posix(0))
    child.close.complete?.should be_true
    authority.target.releases.should eq(1)
  end
end
