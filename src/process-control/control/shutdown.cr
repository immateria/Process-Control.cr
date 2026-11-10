module ProcessControl::Control
  module Group
    class Result
      getter request : Control::Request
      getter mechanism : String
      getter refusal : ProcessControl::Error?

      def initialize(@request, reports : Enumerable(Control::Result), @mechanism, @refusal = nil)
        @reports = reports.to_a.dup
      end

      def reports : Array(Control::Result)
        @reports.dup
      end
    end
  end

  module Shutdown
    struct Policy
      getter stop : Stop::Request?
      getter grace : Time::Span
      getter kill : Kill::Request?

      def initialize(@stop = nil, @grace = 1.second, @kill = nil)
        raise ArgumentError.new("negative grace duration") if @grace < Time::Span.zero
      end
    end

    class Result
      getter state : Wait::State
      getter drain : Containment::Drain::Result

      def initialize(@state, @drain, phases : Enumerable(Control::Group::Result), pending_launches : Enumerable(Spawn::Pending) = [] of Spawn::Pending)
        @phases = phases.to_a.dup
        @pending_launches = pending_launches.to_a.dup
      end

      def phases : Array(Control::Group::Result)
        @phases.dup
      end

      def pending_launches : Array(Spawn::Pending)
        @pending_launches.dup
      end
    end
  end
end
