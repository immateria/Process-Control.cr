{% if flag?(:darwin) %}
  module Fixture::Darwin
    class Registration < PC::Internal::Darwin::Native
      getter queues = 0
      getter ports = 0

      def initialize(@phase : Symbol, &@advance : -> Nil)
      end

      def register_watch(fd : Int32, pid : Int32) : Nil
        @advance.call if @phase == :before_register
        super
        @advance.call if @phase == :after_register
      end

      def close_watch(fd : Int32) : Int32
        @queues += 1
        super
      end

      def release(port : UInt32) : Int32
        @ports += 1
        super
      end
    end

    class Driver < PC::Internal::Darwin::Driver
      property context = 1000_i64
      property available = true
      property open_code = 0
      property read_code = 0
      property retain_code = 0
      property release_code = 0
      property signal_code = 0
      property count = 8_u32
      property pid = 123_u32
      property version = 7_u32
      property open_context : Int64? = nil
      property watch_version : UInt32? = nil
      property registration_error : PC::Observation::Failed? = nil
      property watch_exited = true
      property watch_close_code = 0
      getter watch_closes = 0
      getter watch_polls = 0
      getter references = 0
      getter signals = [] of Tuple(UInt32, UInt32, Int32)
      getter releases = 0
      getter reads = 0

      def available? : Bool
        @available
      end

      def open(pid : Int32) : Tuple(UInt32, Int32)
        return {0_u32, @open_code} unless @open_code == 0
        @references += 1
        if next_context = @open_context
          @context = next_context
        end
        {42_u32, 0}
      end

      def read(port : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
        raise "unowned fixture port" unless port == 42 && @references > 0
        @reads += 1
        words = StaticArray(UInt32, 8).new(0_u32)
        words[5] = @pid
        words[7] = @version
        {words, @count, @read_code}
      end

      def retain(port : UInt32) : Int32
        raise "unowned fixture port" unless port == 42 && @references > 0
        @references += 1 if @retain_code == 0
        @retain_code
      end

      def release(port : UInt32) : Int32
        raise "unowned fixture port" unless port == 42 && @references > 0
        @releases += 1
        @references -= 1 if @release_code == 0
        @release_code
      end

      def signal(token : PC::Internal::Darwin::Token, number : Int32) : Int32
        @signals << {token.pid, token.version, number}
        @signal_code
      end

      def open_watch : Int32
        17
      end

      def register_watch(fd : Int32, pid : Int32) : Nil
        raise "unexpected fixture registration" unless fd == 17 && pid == 123
        if error = @registration_error
          raise error
        end
      end

      def watch_version(pid : Int32) : UInt32
        @watch_version || @version
      end

      def poll_watch(fd : Int32, pid : Int32) : Bool
        @watch_polls += 1
        @watch_exited
      end

      def close_watch(fd : Int32) : Int32
        @watch_closes += 1
        @watch_close_code
      end

      def acquire(*, required = PC::Capability::Request.control, expected : PC::Identity? = nil) : PC::Handle
        PC::Internal::Darwin::Authority.acquire(123, required: required, expected: expected, driver: self)
      end
    end
  end
{% end %}
