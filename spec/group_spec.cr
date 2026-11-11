require "./support/authority"

module Fixture
  class Controller < PC::Containment::Controller
    property population = PC::Containment::Population::Empty
    property calls = 0
    property releases = 0
    property pending : PC::Control::Pending? = nil

    def identity : PC::Containment::Identity?
      PC::Containment::Identity.new("fixture", "owned-group")
    end

    def capabilities : PC::Capability::Snapshot
      PC::Capability::Snapshot.new(%w(control.stop control.kill).map { |name| PC::Capability::Operation.new(name) }, :delegated, "fixture")
    end

    def observe : PC::Containment::Observation
      PC::Containment::Observation.new(identity, @population)
    end

    def control(request : PC::Control::Request, *, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Group::Result
      @calls += 1
      if pending = @pending
        result = PC::Control::Result.new(request, PC::Identity.new(123),
          PC::Control::Delivery::Unknown.new(PC::Diagnostic.new(request.operation, "pending"), pending))
        return PC::Control::Group::Result.new(request, [result], "fixture")
      end
      @population = PC::Containment::Population::Empty
      PC::Control::Group::Result.new(request, [] of PC::Control::Result, "fixture")
    end

    def attach(handle : PC::Handle::Borrowed, *, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Containment::Membership::Result
      request = PC::Control::Stop::Request.new
      result = PC::Control::Result.new(request, handle.identity, PC::Control::Report::Success.new("attached"))
      PC::Containment::Membership::Result.new(handle.identity, identity, result)
    end

    def release(*, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Release::Result
      @releases += 1
      PC::Control::Release::Result.complete
    end
  end

  class Gated < Controller
    getter entered = Channel(Nil).new
    getter proceed = Channel(Nil).new
    @used = false

    def observe : PC::Containment::Observation
      unless @used
        @used = true
        @entered.send(nil)
        @proceed.receive
      end
      super
    end
  end

  module Cleanup
    class Controller < Fixture::Controller
      getter retries = 0
      @participant : PC::Control::Release::Participant? = nil

      def release(*, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Release::Result
        @releases += 1
        @participant ||= PC::Control::Release::Participant.new("retained") do |budget, cancellation|
          @retries += 1
          PC::Control::Release::Record.new("retained", :complete)
        end
        PC::Control::Release::Result.new([
          PC::Control::Release::Record.new("uncertain", :uncertain),
          PC::Control::Release::Record.new("retained", :retryable, participant: @participant),
        ])
      end
    end
  end
end

describe PC::Group do
  it "retries eligible cleanup participants independently of uncertain records" do
    controller = Fixture::Cleanup::Controller.new
    group = PC::Group.new(controller)
    group.close.state.uncertain?.should be_true
    result = group.retry_cleanup
    result.state.uncertain?.should be_true
    result.records[1].state.complete?.should be_true
    controller.retries.should eq(1)
    controller.releases.should eq(1)
  end

  it "reconciles membership admitted while a population query yields" do
    controller = Fixture::Gated.new
    group = PC::Group.new(controller)
    done = Channel(PC::Containment::Drain::Result).new(1)
    spawn { done.send(group.wait_empty(deadline: PC::Wait::Deadline.after(30.milliseconds))) }
    select
    when controller.entered.receive
    when timeout(1.second)
      fail "population query never started"
    end
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "unresolved"))
    group.admit_spawn { pending }
    controller.proceed.send(nil)
    select
    when result = done.receive
      result.state.expired?.should be_true
      result.inflight.should eq(1)
    when timeout(1.second)
      fail "population query did not return"
    end
    pending.publish(PC::Spawn::Rejected.new(PC::Error.new("cancelled fixture")))
    group.close
  end

  it "retains admitted launch tickets independently of returned arrays" do
    group = PC::Group.new(Fixture::Controller.new)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "unresolved"))
    group.admit_spawn { pending }
    group.pending_launches.should eq([pending])
    group.pending_launches.clear
    group.pending_launches.should eq([pending])
    pending.publish(PC::Spawn::Rejected.new(PC::Error.new("cancelled fixture")))
    group.pending_launches.should be_empty
    group.close
  end

  it "retains group authority while admitted control is outstanding" do
    controller = Fixture::Controller.new
    request = PC::Control::Kill::Request.new
    pending = PC::Control::Pending.new(request, PC::Identity.new(123), "fixture")
    controller.pending = pending
    group = PC::Group.new(controller)
    group.kill
    group.close.state.retryable?.should be_true
    controller.releases.should eq(0)
    pending.publish(PC::Control::Result.new(request, PC::Identity.new(123), PC::Control::Report::Success.new("accepted")))
    group.retry_cleanup.complete?.should be_true
    controller.releases.should eq(1)
  end

  it "does not declare drain while an admitted launch can still add members" do
    controller = Fixture::Controller.new
    group = PC::Group.new(controller)
    pending = PC::Spawn::Pending.new(PC::Diagnostic.new("spawn", "awaiting launch"))
    group.admit_spawn { pending }
    result = group.shutdown(deadline: PC::Wait::Deadline.after(Time::Span.zero))
    result.state.expired?.should be_true
    result.drain.inflight.should eq(1)
    group.admit_spawn { fail "closed admission ran a launch" }.should be_a(PC::Spawn::Rejected)
    pending.publish(PC::Spawn::Rejected.new(PC::Error.new("creation refused")))
    group.shutdown(deadline: PC::Wait::Deadline.after(Time::Span.zero)).state.completed?.should be_true
    group.close.complete?.should be_true
  end

  it "honors a requested cooperative phase rather than immediately forcing" do
    controller = Fixture::Controller.new
    controller.population = PC::Containment::Population::Populated
    group = PC::Group.new(controller)
    policy = PC::Control::Shutdown::Policy.new(stop: PC::Control::Stop::Request.new, grace: 1.second, kill: PC::Control::Kill::Request.new)
    result = group.shutdown(policy: policy, deadline: PC::Wait::Deadline.after(2.seconds))
    result.state.completed?.should be_true
    controller.calls.should eq(1)
    group.close
  end

  it "refuses native creation without an explicitly qualified controller" do
    PC::Group.create.should be_a(PC::Containment::Creation::Rejected)
  end
end

{% if flag?(:windows) %}
  describe "Windows Job launcher binding" do
    it "cannot create a process in a different Job through an unbound group" do
      group = PC::Group.new(Fixture::Controller.new)
      owner = PC::Platform::Windows::Job.create.as(PC::Containment::Creation::Created).group
      begin
        command = PC::Command.new(Process.executable_path.not_nil!)
        result = group.spawn(command, launcher: owner.launcher)
        result.as(PC::Spawn::Rejected).error.should be_a(PC::Error::Ownership)
        owner.observe.population.empty?.should be_true
      ensure
        group.close
        owner.close
      end
    end
  end
{% end %}
