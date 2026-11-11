module ProcessControl::Internal::Unix
  class Work
    getter pending : Spawn::Pending
    @mutex = Mutex.new
    @aborting = false
    @session : Session? = nil
    @child : ProcessControl::Child? = nil
    @abort_started = false
    {% if flag?(:darwin) %}
      @helper_process : Internal::Darwin::Bootstrap? = nil
    {% else %}
      @helper_process : ::Process? = nil
    {% end %}
    @helper_wait_started = false
    @startup_failure : ProcessControl::Error? = nil
    @startup_streams : Stream::Endpoints? = nil

    def initialize(@launcher : Platform::Unix::Launcher, @plan : Spawn::Plan, @setup : Array(String))
      @pending = Spawn::Pending.new(Diagnostic.new("spawn", "native launch in progress"))
      @pending.on_abort do |deadline, cancel|
        @mutex.synchronize { @aborting = true }
        if failure = @startup_failure
          if cleanup = @pending.cleanup_result
            if cleanup.retry_participants?
              updated = cleanup.retry_participants(deadline: deadline, cancel: cancel)
              @pending.note_cleanup(updated)
              @pending.publish_abort(Spawn::Rejected.new(failure, updated, attempted: true)) if updated.complete?
            end
          end
        end
        begin_abort
        @pending.resolve(deadline: deadline, cancel: cancel)
      end
    end

    def start : Nil
      spawn(name: "process-control-launch") { run }
    end

    private def aborted? : Bool
      @mutex.synchronize { @aborting }
    end

    private def run : Nil
      directory = "/tmp/process-control-#{Random::Secure.hex(12)}"
      path = File.join(directory, "channel")
      server = nil.as(UNIXServer?)
      socket = nil.as(UNIXSocket?)
      streams = nil.as(Stream::Endpoints?)
      released = false
      begin
        Dir.mkdir(directory, 0o700)
        server = UNIXServer.new(path)
        server.read_timeout = @launcher.startup_timeout
        token = Random::Secure.hex(16)
        process = create_helper(path, token)
        socket = server.accept
        socket.read_timeout = @launcher.startup_timeout
        greeting = socket.gets(limit: 192, chomp: true).try(&.split)
        unless greeting && greeting.size == 5 && greeting[0] == "HELLO" && greeting[1] == "2" && greeting[2] == token
          raise Observation::Failed.new("invalid native helper handshake")
        end
        signal_limit = greeting[3].to_i32
        duplicate_command = greeting[4].to_i32
        streams = endpoints(process, duplicate_command)
        # Helper bookkeeping may close its original stdio wrappers. Those were
        # closed after atomic duplication; the shard's endpoints are independent.
        collect_helper
        if aborted?
          socket << "ABORT #{token}\n"
          socket.flush
          raise Observation::Failed.new("helper failed to end after abort") if socket.gets
          reject(Error.new("launch aborted before target release"), streams)
          return
        end
        released = true
        socket << "START #{token}\n"
        socket.flush
        response = socket.gets(limit: 192, chomp: true).try(&.split)
        unless response && response.size == 3 && response[1] == token
          raise Observation::Failed.new("missing native launch acknowledgment")
        end
        if response[0].in?("REJECTED", "SETUP", "CREATION")
          code = response[2].to_i64
          raise Observation::Failed.new("helper did not close after rejection") if socket.gets
          stage = case response[0]
                  when "SETUP"    then "setup"
                  when "CREATION" then "creation"
                  else                 "exec"
                  end
          diagnostic = Diagnostic.new("spawn", "native target #{stage} failed", native_domain: "errno", native_code: code, stage: stage)
          reject(Error.new(diagnostic.message, diagnostic), streams)
          return
        end
        raise Observation::Failed.new("unexpected launch acknowledgment") unless response[0] == "STARTED"
        socket.read_timeout = nil
        session = Session.new(socket, token, response[2].to_i64, signal_limit)
        @mutex.synchronize { @session = session }
        socket = nil # ownership moved to the independent collector
        registration = Spawn::Registration.new(Authority.new(session), session.source, streams)
        result = registration.publish(required: @plan.required)
        case result
        when Spawn::Started
          @mutex.synchronize { @child = result.child }
          if aborted?
            begin_abort
          else
            @pending.publish(result)
          end
        when Spawn::Rejected
          @pending.publish(result)
        when Spawn::Pending
          @pending.retain(registration)
        end
      rescue ex
        stream_release = streams.try(&.close)
        cleanup_error = nil.as(Exception?)
        unless @helper_wait_started
          begin
            @helper_process.try(&.close)
          rescue close_error
            cleanup_error = close_error
          ensure
            collect_helper
          end
        end
        if cleanup_error
          diagnostic = Diagnostic.new("spawn.cleanup", cleanup_error.message || cleanup_error.class.name)
          combined = Control::Release::Result.new((stream_release.try(&.records) || [] of Control::Release::Record) +
                                                  [Control::Release::Record.new("helper stdio", :uncertain, diagnostic)])
          @pending.note_cleanup(combined)
        elsif stream_release && !stream_release.complete?
          @pending.note_cleanup(stream_release)
        end
        if released || cleanup_error || (stream_release && !stream_release.complete?)
          # A target may exist; retain the launch owner. Closing the channel
          # makes the native owner continue reaping without fabricating status.
          @pending.note(Diagnostic.new("spawn", ex.message || ex.class.name, stage: "acknowledgment"))
          unless released
            @startup_failure = Error.new(ex.message || ex.class.name)
            @startup_streams = streams
          end
        else
          @pending.publish(Spawn::Rejected.new(Error.new(ex.message || ex.class.name), attempted: true))
        end
      ensure
        socket.try { |connection| connection.close unless connection.closed? }
        server.try { |listener| listener.close unless listener.closed? }
        File.delete(path) if File.exists?(path)
        Dir.delete(directory) if Dir.exists?(directory)
      end
    end

    private def reject(error : ProcessControl::Error, streams : Stream::Endpoints) : Nil
      cleanup = streams.close
      if cleanup.complete?
        @pending.publish(Spawn::Rejected.new(error, cleanup, attempted: true))
      else
        @startup_failure = error
        @startup_streams = streams
        @pending.note_cleanup(cleanup)
        @pending.note(Diagnostic.new("spawn.cleanup", "target accounted for; startup resource cleanup remains #{cleanup.state}"))
      end
    end

    private def collect_helper : Nil
      process = @helper_process
      return if @helper_wait_started || !process
      @helper_wait_started = true
      spawn(name: "process-control-helper-reap") do
        begin
          process.wait
        rescue
          # Never use the helper's PID-keyed runtime status as target status.
        end
      end
    end

    private def begin_abort : Nil
      child = @mutex.synchronize do
        if !@abort_started && (value = @child)
          @abort_started = true
          value
        end
      end
      return unless child
      spawn(name: "process-control-launch-abort") do
        result = child.handle.kill
        if outcome = result.disposition.as?(Control::Delivery::Unknown)
          outcome.pending.try(&.wait)
        end
        status = child.wait_exit
        if status.state.completed?
          release = child.close
          if release.complete?
            @pending.publish_abort(Spawn::Rejected.new(Error.new("launch aborted and target collected"), attempted: true))
          end
        end
      end
    end

    private def redirect(spec : Stream::Spec) : ::Process::Stdio
      case spec
      when Stream::Inherit               then ::Process::Redirect::Inherit
      when Stream::Close                 then ::Process::Redirect::Close
      when Stream::Pipe, Stream::Capture then ::Process::Redirect::Pipe
      when IO::FileDescriptor            then spec
      else
        raise Error::Unsupported.new("unsupported stdio policy")
      end
    end

    private def create_helper(path : String, token : String)
      arguments = [path, token] + @setup + ["--", @plan.executable] + @plan.args
      {% if flag?(:darwin) %}
        process = Internal::Darwin::Bootstrap.new(@launcher.helper, arguments,
          env: @plan.environment, chdir: @plan.directory,
          input: redirect(@plan.stdio.input), output: redirect(@plan.stdio.output), error: redirect(@plan.stdio.error))
        @helper_process = process
        process.start
        process
      {% else %}
        process = ::Process.new(@launcher.helper, arguments,
          env: @plan.environment, clear_env: true, chdir: @plan.directory,
          input: redirect(@plan.stdio.input), output: redirect(@plan.stdio.output), error: redirect(@plan.stdio.error))
        @helper_process = process
        process
      {% end %}
    end

    private def duplicate(io : IO::FileDescriptor, command : Int32) : Stream::Endpoint
      fd = descriptor_command(io.fd, command, 3)
      begin
        flags = descriptor_command(fd, LibC::F_GETFL)
        descriptor_command(fd, LibC::F_SETFL, flags | LibC::O_NONBLOCK)
        result = Stream::Endpoint.new(IO::FileDescriptor.new(fd))
      rescue ex
        {% if flag?(:darwin) %}
          ::Native::Kernel::Darwin::Descriptor.close(fd)
        {% else %}
          LibC.close(fd)
        {% end %}
        raise ex
      end
      io.close
      result
    end

    private def descriptor_command(fd : Int32, command : Int32, argument : Int32 = 0) : Int32
      {% if flag?(:darwin) %}
        result = ::Native::Kernel::Darwin::Descriptor.fcntl(fd, command, argument)
        unless result.error == 0
          detail = Diagnostic.new("spawn.descriptor", "Darwin descriptor command failed",
            native_domain: "errno", native_code: result.error.to_i64, stage: "stdio")
          raise Observation::Failed.new(detail.message, detail)
        end
        result.primary.to_i32!
      {% else %}
        value = LibC.fcntl(fd, command, argument)
        raise IO::Error.from_errno("fcntl") if value < 0
        value
      {% end %}
    end

    private def endpoints(process, command : Int32) : Stream::Endpoints
      prepared = [] of Stream::Endpoint
      input = @plan.stdio.input.is_a?(Stream::Pipe) ? duplicate(process.input, command) : nil
      prepared << input if input
      output = nil.as(Stream::Endpoint?)
      error = nil.as(Stream::Endpoint?)
      captures = [] of Stream::Capture::Buffer
      case spec = @plan.stdio.output
      when Stream::Pipe
        output = duplicate(process.output, command)
        prepared << output
      when Stream::Capture
        endpoint = duplicate(process.output, command)
        prepared << endpoint
        captures << Stream::Capture::Buffer.new("stdout", endpoint, spec.budget)
      end
      case spec = @plan.stdio.error
      when Stream::Pipe
        error = duplicate(process.error, command)
        prepared << error
      when Stream::Capture
        endpoint = duplicate(process.error, command)
        prepared << endpoint
        captures << Stream::Capture::Buffer.new("stderr", endpoint, spec.budget)
      end
      Stream::Endpoints.new(input, output, error, captures)
    rescue ex
      captures.try(&.each(&.cut))
      prepared.try do |endpoints|
        endpoints.each { |endpoint| endpoint.close unless endpoint.closed? }
      end
      raise ex
    end
  end
end
