module ProcessControl::Internal::Darwin
  # All local views share the same one-shot event and its terminal evidence.
  # The queue is closed only after the last view releases it.
  class Watch
    @mutex = Mutex.new
    @views = 1
    @observation : ProcessControl::Observation? = nil
    @failure : Wait::Failure? = nil

    def initialize(@fd : Int32, @identity : ProcessControl::Identity, @driver : Driver)
    end

    def retain : Nil
      @mutex.synchronize { @views += 1 }
    end

    def observe : ProcessControl::Observation?
      @mutex.synchronize do
        return @observation if @observation
        begin
          if @driver.poll_watch(@fd, @identity.pid.to_i32)
            @observation = ProcessControl::Observation.new(@identity, termination: :terminated)
          end
        rescue ex : ProcessControl::Observation::Failed
          @failure = Wait::Failure.new(ex)
          @observation = ProcessControl::Observation.new(@identity, diagnostic: ex.diagnostic)
        end
        @observation
      end
    end

    def failure : Wait::Failure?
      @mutex.synchronize { @failure }
    end

    def release : Control::Release::Record?
      @mutex.synchronize do
        @views -= 1
        return unless @views == 0
        code = @driver.close_watch(@fd)
        return if code == 0
        diagnostic = Diagnostic.new("handle.close", "kqueue close failed", native_domain: "errno", native_code: code.to_i64, stage: "close-watch")
        Control::Release::Record.new("Darwin exit watch", :uncertain, diagnostic)
      end
    end
  end
end
