module ProcessControl::Inspection
  MAX_ROWS = 65_536

  class Snapshot
    getter? truncated : Bool
    getter skipped : Int32

    def initialize(observations : Array(ProcessControl::Observation), @truncated : Bool)
      @observations = observations.dup
      @skipped = @observations.count { |observation| !observation.diagnostic.nil? }
    end

    def observations : Array(ProcessControl::Observation)
      @observations.dup
    end

    # Every selected PID yielded a record and the caller's limit fit the roster.
    def complete? : Bool
      !@truncated && @skipped == 0
    end
  end

  # Enumerates visible positive PIDs and samples each separately. A skipped
  # row keeps its PID and native diagnostic. The roster and rows may reflect
  # different instants. These observations carry no process authority.
  def self.snapshot(*, limit : Int = 4096) : Snapshot
    raise ArgumentError.new("inspection limit must be in 1..#{MAX_ROWS}") unless 1 <= limit <= MAX_ROWS
    {% if flag?(:darwin) %}
      Internal::Darwin::Inspection.snapshot(limit.to_i)
    {% else %}
      raise Error::Unsupported.new("process inspection is unavailable on this platform")
    {% end %}
  end
end
