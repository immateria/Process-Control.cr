module ProcessControl::Control
  struct Refused
    getter reason : ProcessControl::Error

    def initialize(@reason)
    end
  end

  struct Satisfied
    getter observation : ProcessControl::Observation

    def initialize(@observation)
    end
  end

  module Report
    struct Success
      getter receipt : String

      def initialize(@receipt)
      end
    end

    struct Failure
      getter diagnostic : ProcessControl::Diagnostic

      def initialize(@diagnostic)
      end
    end

    class Partial
      @reports : Array(Control::Result)

      def initialize(reports : Enumerable(Control::Result))
        @reports = reports.to_a.dup
        raise ArgumentError.new("partial report requires member/stage reports") if @reports.empty?
      end

      def reports : Array(Control::Result)
        @reports.dup
      end
    end
  end

  module Delivery
    struct Unknown
      getter diagnostic : ProcessControl::Diagnostic
      getter pending : Control::Pending?

      def initialize(@diagnostic, @pending = nil)
      end
    end
  end

  alias Disposition = Refused | Satisfied | Report::Success | Report::Failure | Report::Partial | Delivery::Unknown

  enum Postcondition
    Confirmed
    Contradicted
    Unknown
    Skipped
  end

  struct Result
    getter request : Request
    getter subject : ProcessControl::Identity
    getter disposition : Disposition
    getter mechanism : String
    getter postcondition : Postcondition

    def initialize(@request, @subject, @disposition, @mechanism = "provider", @postcondition = Postcondition::Skipped)
    end

    def pending_owners : Array(Pending)
      case value = @disposition
      when Delivery::Unknown
        value.pending.try { |owner| [owner] } || [] of Pending
      when Report::Partial
        value.reports.flat_map(&.pending_owners).uniq
      else
        [] of Pending
      end
    end
  end
end
