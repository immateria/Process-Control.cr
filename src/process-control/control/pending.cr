module ProcessControl::Control
  class Pending
    getter request : Request
    @mutex = Mutex.new
    @result : Result? = nil
    @closed = false
    @callbacks = [] of Proc(Nil)
    @callback_failures = [] of ProcessControl::Diagnostic

    def initialize(@request : Request, @identity : ProcessControl::Identity, @mechanism : String)
    end

    # Provider completion, exactly once. Closing a consumer's observation does
    # not cancel this producer or release its lifetime obligations.
    def publish(result : Result) : Nil
      callbacks = @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("control operation already settled") if @result
        @result = result
        copied = @callbacks.dup
        @callbacks.clear
        copied
      end
      notify(callbacks)
    end

    def on_settle(&callback : -> Nil) : Nil
      settled = @mutex.synchronize do
        if @result
          true
        else
          @callbacks << callback
          false
        end
      end
      notify([callback]) if settled
    end

    def callback_failures : Array(ProcessControl::Diagnostic)
      @mutex.synchronize { @callback_failures.dup }
    end

    private def notify(callbacks : Array(Proc(Nil))) : Nil
      failures = Internal::Callbacks.run("control.settle", callbacks)
      @mutex.synchronize { @callback_failures.concat(failures) }
    end

    def latest : Result?
      @mutex.synchronize { @result }
    end

    def wait(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Result
      loop do
        if result = latest
          return result
        end
        closed = @mutex.synchronize { @closed }
        if closed || cancel.try(&.cancelled?) || deadline.expired?
          diagnostic = ProcessControl::Diagnostic.new(@request.operation, closed ? "pending observation closed" : "control completion not observed")
          return Result.new(@request, @identity, Delivery::Unknown.new(diagnostic, closed ? nil : self), @mechanism, :unknown)
        end
        deadline.pause
      end
    end

    def close : Nil
      @mutex.synchronize { @closed = true }
    end
  end
end
