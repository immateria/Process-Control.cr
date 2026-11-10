module ProcessControl::Stream
  struct Inherit; end

  struct Close; end

  struct Pipe; end

  struct Capture
    struct Budget
      getter max_bytes : Int32

      def initialize(@max_bytes = 65_536)
        raise ArgumentError.new("capture size must be nonnegative") if @max_bytes < 0
      end
    end

    getter budget : Budget

    def initialize(@budget = Budget.new)
    end
  end

  alias Spec = Inherit | Close | Pipe | Capture | IO::FileDescriptor

  struct Stdio
    getter input : Spec
    getter output : Spec
    getter error : Spec

    def initialize(@input = Inherit.new, @output = Inherit.new, @error = Inherit.new)
      raise ArgumentError.new("input capture is not a readable source") if @input.is_a?(Capture)
    end
  end

  module Drain
    struct Policy
      getter cut_after : Time::Span?

      def initialize(@cut_after = nil)
        if duration = @cut_after
          raise ArgumentError.new("negative drain duration") if duration < Time::Span.zero
        end
      end

      def self.cut_after(span : Time::Span) : self
        new(span)
      end
    end

    struct Record
      getter name : String
      getter settled : Bool
      getter cut : Bool
      getter diagnostic : ProcessControl::Diagnostic?

      def initialize(@name, @settled, @cut = false, @diagnostic = nil)
      end
    end
  end
end
