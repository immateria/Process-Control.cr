module ProcessControl::Wait
  enum State
    Completed
    Expired
    Cancelled
    Closed
    Failed
  end

  struct Failure
    getter error : ProcessControl::Error

    def initialize(@error)
    end
  end

  module Collection
    class Failed < ProcessControl::Error; end
  end

  module Exit
    enum Domain
      Posix
      Windows
      Provider
    end

    enum Reason
      Exited
      Signaled
      Unknown
    end

    struct Info
      getter domain : Domain
      getter raw : UInt32
      getter reason : Reason
      getter code : UInt32?
      getter signal : Int32?
      getter core_dumped : Bool?

      def initialize(@domain, @raw, @reason, @code = nil, @signal = nil, @core_dumped = nil)
      end

      def self.posix(raw : Int32) : self
        bits = raw.to_u32!
        signal = raw & 0x7f
        if signal == 0
          new(Domain::Posix, bits, Reason::Exited, ((raw >> 8) & 0xff).to_u32)
        elsif signal != 0x7f
          new(Domain::Posix, bits, Reason::Signaled, signal: signal, core_dumped: (raw & 0x80) != 0)
        else
          new(Domain::Posix, bits, Reason::Unknown)
        end
      end

      def success? : Bool
        @reason.exited? && @code == 0
      end
    end

    struct Result
      getter state : State
      getter observation : ProcessControl::Observation
      getter failure : Failure?

      def initialize(@state, @observation, @failure = nil)
        raise ArgumentError.new("failed wait requires failure evidence") if @state.failed? && !@failure
      end
    end
  end

  module Child
    struct Result
      getter state : State
      getter identity : ProcessControl::Identity
      getter info : Exit::Info?
      getter termination : ProcessControl::Observation::Termination
      getter failure : Failure?

      def initialize(@state, @identity, @info = nil, @termination = ProcessControl::Observation::Termination::Unknown, @failure = nil)
        raise ArgumentError.new("completed child wait requires native status") if @state.completed? && !@info
        raise ArgumentError.new("failed wait requires failure evidence") if @state.failed? && !@failure
      end
    end
  end
end
