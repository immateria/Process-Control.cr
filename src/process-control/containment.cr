module ProcessControl::Containment
  struct Identity
    getter mechanism : String
    getter native : String

    def initialize(@mechanism, @native)
    end
  end

  enum Population
    Empty
    Populated
    Unknown
  end

  struct Observation
    getter identity : Identity?
    getter population : Population
    getter sampled_at : Clock::Instant
    getter diagnostic : ProcessControl::Diagnostic?

    def initialize(@identity, @population = Population::Unknown, @sampled_at = Clock.now, @diagnostic = nil)
    end
  end

  struct Request
    getter required : Capability::Request

    def initialize(@required = Capability::Request.new([] of Capability::Operation))
    end
  end

  module Membership
    struct Result
      getter subject : ProcessControl::Identity
      getter group : Containment::Identity?
      getter control : Control::Result

      def initialize(@subject, @group, @control)
      end
    end
  end

  module Drain
    struct Result
      getter state : Wait::State
      getter observation : Containment::Observation
      getter inflight : Int32
      getter admission_closed : Bool
      getter failure : Wait::Failure?

      def initialize(@state, @observation, @inflight, @admission_closed, @failure = nil)
        raise ArgumentError.new("failed drain requires evidence") if @state.failed? && !@failure
      end
    end
  end

  module Creation
    struct Created
      getter group : ProcessControl::Group

      def initialize(@group)
      end
    end

    struct Rejected
      getter error : ProcessControl::Error

      def initialize(@error)
      end
    end

    alias Result = Created | Rejected
  end

  abstract class Controller
    abstract def identity : Identity?
    abstract def capabilities : Capability::Snapshot
    abstract def observe : Observation
    abstract def control(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Group::Result
    abstract def attach(handle : ProcessControl::Handle::Borrowed, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Membership::Result
    abstract def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
  end
end
