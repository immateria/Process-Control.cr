module ProcessControl::Control
  abstract class Request
    abstract def operation : String
  end

  module Stop
    class Request < Control::Request
      def operation : String
        "control.stop"
      end
    end
  end

  module Kill
    class Request < Control::Request
      getter exit_code : UInt32?

      def initialize(@exit_code = nil)
      end

      def operation : String
        "control.kill"
      end
    end
  end

  class Signal < Request
    getter domain : String
    getter value : Int32

    def initialize(@domain, @value)
      raise ArgumentError.new("signal must be positive") unless @value > 0
    end

    def operation : String
      "control.signal"
    end
  end

  module Suspend
    class Request < Control::Request
      def operation : String
        "control.suspend"
      end
    end
  end

  module Resume
    class Request < Control::Request
      def operation : String
        "control.resume"
      end
    end
  end
end
