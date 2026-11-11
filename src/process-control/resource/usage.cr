module ProcessControl::Resource
  # Terminal Darwin accounting for an owned target, including usage from
  # descendants already collected into that target's cumulative child usage.
  struct Usage
    struct Time
      getter seconds : Int64
      getter microseconds : Int32

      def initialize(@seconds, @microseconds)
        unless @seconds >= 0 && 0 <= @microseconds < 1_000_000
          raise ArgumentError.new("invalid resource usage time")
        end
      end

      def to_span : ::Time::Span
        ::Time::Span.new(seconds: @seconds, nanoseconds: @microseconds * 1000)
      end
    end

    getter user : Time
    getter system : Time
    getter max_rss_bytes : Int64
    getter shared_memory : Int64
    getter data_memory : Int64
    getter stack_memory : Int64
    getter reclaims : Int64
    getter faults : Int64
    getter swaps : Int64
    getter input_blocks : Int64
    getter output_blocks : Int64
    getter sent : Int64
    getter received : Int64
    getter signals : Int64
    getter voluntary_switches : Int64
    getter involuntary_switches : Int64

    def initialize(@user, @system, @max_rss_bytes, @shared_memory, @data_memory,
                   @stack_memory, @reclaims, @faults, @swaps, @input_blocks,
                   @output_blocks, @sent, @received, @signals,
                   @voluntary_switches, @involuntary_switches)
      counters = {@max_rss_bytes, @shared_memory, @data_memory, @stack_memory,
                  @reclaims, @faults, @swaps, @input_blocks, @output_blocks,
                  @sent, @received, @signals, @voluntary_switches, @involuntary_switches}
      raise ArgumentError.new("negative resource usage counter") if counters.any? { |value| value < 0 }
    end

    def domain : String
      "darwin.wait4"
    end
  end
end
