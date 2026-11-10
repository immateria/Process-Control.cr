require "../spec_helper"

module Fixture
  class Target
    getter identity = PC::Identity.new(123)
    getter source : PC::Spawn::Status::Source
    property calls = 0
    property releases = 0
    property pending : PC::Control::Pending? = nil

    def initialize
      @source = PC::Spawn::Status::Source.new(@identity)
    end
  end

  class Authority < PC::Control::Authority
    getter target : Target

    def initialize(@target = Target.new)
    end

    def identity : PC::Identity
      @target.identity
    end

    def capabilities : PC::Capability::Snapshot
      PC::Capability::Snapshot.new(
        %w(handle.observe wait.exit control.stop control.kill control.signal control.suspend control.resume).map { |name| PC::Capability::Operation.new(name) },
        :delegated, "fixture")
    end

    def observe : PC::Observation
      PC::Observation.new(identity, presence: :present,
        termination: @target.source.latest ? PC::Observation::Termination::Terminated : PC::Observation::Termination::Alive)
    end

    def perform(request : PC::Control::Request, *, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Result
      @target.calls += 1
      disposition = if pending = @target.pending
                      PC::Control::Delivery::Unknown.new(PC::Diagnostic.new(request.operation, "awaiting receipt"), pending)
                    else
                      PC::Control::Report::Success.new("fixture accepted")
                    end
      PC::Control::Result.new(request, identity, disposition, "fixture")
    end

    def duplicate : PC::Control::Authority
      Authority.new(@target)
    end

    def release(*, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Release::Result
      @target.releases += 1
      PC::Control::Release::Result.complete
    end
  end

  class Retrying < Authority
    def release(*, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Release::Result
      @target.releases += 1
      if @target.releases == 1
        PC::Control::Release::Result.new([PC::Control::Release::Record.new("provider resource", :retryable)])
      else
        PC::Control::Release::Result.complete
      end
    end
  end

  class Mixed < Authority
    getter retries = 0
    @participant : PC::Control::Release::Participant? = nil

    def initialize
      super
      @participant = PC::Control::Release::Participant.new("retained") do |deadline, cancel|
        @retries += 1
        PC::Control::Release::Record.new("retained", :complete)
      end
    end

    def release(*, deadline : PC::Wait::Deadline, cancel : PC::Wait::Cancellation?) : PC::Control::Release::Result
      @target.releases += 1
      PC::Control::Release::Result.new([
        PC::Control::Release::Record.new("uncertain close", :uncertain),
        PC::Control::Release::Record.new("retained", :retryable, participant: @participant),
      ])
    end
  end

  class Limited < Retrying
    def capabilities : PC::Capability::Snapshot
      PC::Capability::Snapshot.new([PC::Capability::Operation.new("handle.observe")], :delegated, "fixture")
    end
  end

  class Duplicating < Authority
    def duplicate : PC::Control::Authority
      Limited.new(@target)
    end
  end
end
