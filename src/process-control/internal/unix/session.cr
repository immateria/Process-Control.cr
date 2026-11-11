require "./protocol"

module ProcessControl::Internal::Unix
  class Session
    getter source : Spawn::Status::Source
    getter identity : ProcessControl::Identity
    @mutex = Mutex.new
    @permit = Channel(Nil).new(1)
    @operations = {} of UInt64 => Control::Pending
    @sequence = 0_u64
    @done = false
    @context = Thread.current
    @started_at = Clock.now

    def initialize(@socket : UNIXSocket, @token : String, pid : Int64, @signal_limit : Int32)
      @identity = ProcessControl::Identity.new(pid)
      @source = Spawn::Status::Source.new(@identity)
      @permit.send(nil)
      spawn(name: "process-control-status") { receive }
    end

    def done? : Bool
      @mutex.synchronize { @done }
    end

    def observe : Observation
      if result = @source.latest
        presence = result.info ? Observation::Presence::Absent : Observation::Presence::Unknown
        diagnostic = result.failure.try do |failure|
          failure.error.diagnostic || Diagnostic.new("wait.exit", failure.error.message || "status collection failed", stage: "collection")
        end
        Observation.new(@identity, presence: presence, termination: result.termination, diagnostic: diagnostic)
      else
        Observation.new(@identity, presence: :present, sampled_at: @started_at)
      end
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      unless Thread.current == @context
        return refused(request, Error::Context::Mismatch.new("Unix authority belongs to another execution thread"))
      end
      number = case request
               when Control::Stop::Request then ::Signal::TERM.value
               when Control::Kill::Request
                 return refused(request, Error::Unsupported.new("Windows exit code is unavailable on Unix")) if request.exit_code
                 ::Signal::KILL.value
               when Control::Suspend::Request then ::Signal::STOP.value
               when Control::Resume::Request  then ::Signal::CONT.value
               when Control::Signal
                 return refused(request, Error::Unsupported.new("signal domain is not POSIX")) unless request.domain == "posix"
                 request.value
               else
                 return refused(request, Error::Unsupported.new("unknown control request"))
               end
      unless number > 0 && number < @signal_limit
        return refused(request, Error::Unsupported.new("signal is outside the native range"))
      end
      loop do
        select
        when @permit.receive
          break
        else
          return refused(request, Error.new("control budget ended before provider admission")) if deadline.expired? || cancel.try(&.cancelled?)
          deadline.pause
        end
      end
      if terminal = @source.latest
        @permit.send(nil)
        if terminal.info && (request.is_a?(Control::Stop::Request) || request.is_a?(Control::Kill::Request))
          return Control::Result.new(request, @identity, Control::Satisfied.new(observe), "unix-helper-v2", :confirmed)
        end
        return refused(request, Error::Missing.new("target is terminated or collection failed"))
      end
      if done? || (deadline.expired? && !deadline.immediate?) || cancel.try(&.cancelled?)
        @permit.send(nil)
        return refused(request, Error::Closed.new("control transport unavailable or budget ended"))
      end
      pending = Control::Pending.new(request, @identity, "unix-helper-v2")
      sequence = @mutex.synchronize do
        @sequence += 1
        @operations[@sequence] = pending
        @sequence
      end
      begin
        @socket.write_timeout = deadline.remaining
        @socket << "SIGNAL #{@token} #{sequence} #{number}\n"
        @socket.flush
      rescue ex
        disconnect(ex)
      end
      pending.wait(deadline: deadline, cancel: cancel)
    end

    private def refused(request : Control::Request, reason : ProcessControl::Error) : Control::Result
      Control::Result.new(request, @identity, Control::Refused.new(reason), "unix-helper-v2")
    end

    private def receive : Nil
      while line = @socket.gets(limit: Protocol::FRAME_LIMIT, chomp: false)
        raise Observation::Failed.new("incomplete native protocol frame") unless line.ends_with?('\n')
        parts = line.split
        unless parts.size >= 3 && parts[1] == @token
          raise Error::Context::Mismatch.new("native protocol identity mismatch")
        end
        case parts[0]
        when "ACK"
          raise Observation::Failed.new("malformed control receipt") unless parts.size == 4
          sequence = parts[2].to_u64
          code = parts[3].to_i32
          pending = @mutex.synchronize { @operations.delete(sequence) }
          raise Observation::Failed.new("unexpected control receipt") unless pending
          request = pending.request
          disposition = if code == 0
                          Control::Report::Success.new("helper accepted sequence #{sequence}")
                        else
                          Control::Report::Failure.new(Diagnostic.new(request.operation, "native signal failed", native_domain: "errno", native_code: code.to_i64))
                        end
          pending.publish(Control::Result.new(request, @identity, disposition, "unix-helper-v2"))
          @permit.send(nil)
        when "EXIT"
          @source.publish(Protocol.exit(parts))
        when "FAILED"
          raise Observation::Failed.new("native collector failed: errno #{parts[2]}")
        else
          raise Observation::Failed.new("unexpected native protocol message")
        end
      end
      disconnect(Wait::Collection::Failed.new("helper channel ended before a target result"))
    rescue ex
      disconnect(ex)
    end

    private def disconnect(error : Exception) : Nil
      operations = @mutex.synchronize do
        return if @done
        @done = true
        values = @operations.values
        @operations.clear
        values
      end
      @socket.close unless @socket.closed?
      unless @source.latest
        @source.fail(Wait::Collection::Failed.new(error.message || error.class.name))
      end
      operations.each do |pending|
        diagnostic = Diagnostic.new(pending.request.operation, error.message || error.class.name, stage: "receipt")
        pending.publish(Control::Result.new(pending.request, @identity, Control::Delivery::Unknown.new(diagnostic), "unix-helper-v2", :unknown))
        @permit.send(nil)
      end
    end
  end

  class Authority < Control::Authority
    def initialize(@session : Session)
    end

    def identity : ProcessControl::Identity
      @session.identity
    end

    def capabilities : Capability::Snapshot
      Platform::Unix::Launcher.capabilities
    end

    def observe : Observation
      @session.observe
    end

    def wait_failure : Wait::Failure?
      @session.source.latest.try(&.failure)
    end

    def perform(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Result
      @session.perform(request, deadline: deadline, cancel: cancel)
    end

    def duplicate : Control::Authority
      Authority.new(@session)
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      # This releases a control view. The independent status collector retains
      # the helper/connection until its target obligation ends.
      Control::Release::Result.complete
    end
  end
end
