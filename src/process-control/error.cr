module ProcessControl
  class Error < Exception
    getter diagnostic : Diagnostic?

    def initialize(message : String, @diagnostic : Diagnostic? = nil)
      super(message)
    end

    class Unsupported < Error; end

    class Missing < Error; end

    class Closed < Error; end

    class Ownership < Error; end

    module Access
      class Denied < ProcessControl::Error; end
    end

    module Context
      class Mismatch < ProcessControl::Error; end
    end
  end
end
