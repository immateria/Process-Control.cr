module ProcessControl::Spawn
  struct Started
    getter child : ProcessControl::Child

    def initialize(@child)
    end
  end

  struct Rejected
    getter error : ProcessControl::Error
    getter cleanup : Control::Release::Result
    getter attempted : Bool

    def initialize(@error, @cleanup = Control::Release::Result.complete, @attempted = false)
      raise ArgumentError.new("rejection cannot discard incomplete cleanup") unless @cleanup.complete?
    end
  end

  alias Result = Started | Rejected | Pending

  class Pending
    @mutex = Mutex.new
    @terminal : (Started | Rejected)? = nil
    @transferred = false
    @aborting = false
    @callbacks = [] of Proc(Nil)
    @aborter : Proc(Wait::Deadline, Wait::Cancellation?, Result)? = nil
    @retained : Registration? = nil
    @cleanup_result : Control::Release::Result? = nil

    def initialize(@diagnostic)
    end

    def diagnostic : ProcessControl::Diagnostic
      @mutex.synchronize { @diagnostic }
    end

    def note(diagnostic : ProcessControl::Diagnostic) : Nil
      @mutex.synchronize { @diagnostic = diagnostic }
    end

    def cleanup_result : Control::Release::Result?
      @mutex.synchronize { @cleanup_result }
    end

    def note_cleanup(result : Control::Release::Result) : Nil
      @mutex.synchronize { @cleanup_result = result }
    end

    def retain(owner : Registration) : Nil
      @mutex.synchronize { @retained = owner }
    end

    def publish(result : Started | Rejected) : Nil
      callbacks = @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("launch already settled") if @terminal
        @terminal = result
        if @aborting && result.is_a?(Started)
          [] of Proc(Nil)
        else
          copied = @callbacks.dup
          @callbacks.clear
          copied
        end
      end
      callbacks.each(&.call)
    end

    def on_settle(&callback : -> Nil) : Nil
      settled = @mutex.synchronize do
        if @terminal && !(@aborting && @terminal.is_a?(Started))
          true
        else
          @callbacks << callback
          false
        end
      end
      callback.call if settled
    end

    def on_abort(&aborter : Wait::Deadline, Wait::Cancellation? -> Result) : Nil
      @mutex.synchronize { @aborter = aborter }
    end

    def resolve(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Result
      loop do
        terminal = @mutex.synchronize do
          raise ProcessControl::Error::Ownership.new("child ownership already transferred") if @transferred
          if (value = @terminal) && !(@aborting && value.is_a?(Started))
            @transferred = true if value.is_a?(Started)
            value
          end
        end
        return terminal if terminal
        return self if cancel.try(&.cancelled?) || deadline.expired?
        deadline.pause
      end
    end

    def abort(*, deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Result
      aborter = @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("child ownership already transferred") if @transferred
        if terminal = @terminal.as?(Rejected)
          return terminal
        end
        @aborting = true
        @aborter
      end
      aborter.try { |callback| callback.call(deadline, cancel) } || self
    end

    # An explicit abort may replace an offered, still-owned Child after the
    # provider proves its cleanup. It cannot replace a transferred Child.
    def publish_abort(result : Rejected) : Nil
      callbacks = @mutex.synchronize do
        raise ProcessControl::Error::Ownership.new("child ownership already transferred") if @transferred
        @terminal = result
        @aborting = false
        copied = @callbacks.dup
        @callbacks.clear
        copied
      end
      callbacks.each(&.call)
    end

    def close : Control::Release::Result
      @mutex.synchronize do
        unless @terminal.is_a?(Rejected)
          raise ProcessControl::Error::Ownership.new("unresolved or transferred launch cannot be discarded")
        end
      end
      Control::Release::Result.complete
    end
  end
end
