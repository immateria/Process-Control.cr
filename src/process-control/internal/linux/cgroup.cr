require "./cgroup/native"

module ProcessControl::Internal::Linux
  class Cgroup < Containment::Controller
    MECHANISM = "linux-cgroup-v2"

    getter identity : Containment::Identity? = nil
    getter capabilities : Capability::Snapshot = Capability::Snapshot.new([] of Capability::Operation, :delegated, MECHANISM)
    @mutex = Mutex.new
    @release : Control::Release::Result? = nil
    @birth : Containment::Birth? = nil
    @birth_disabled = false
    @freeze_requested = false

    def initialize(@path : String)
      @context = Process.pid.to_i64
      @directory = Native.open_directory(@path)
      @descriptors = {"directory" => @directory}
    end

    def capture : Nil
      device, inode = Native.directory_identity(@directory)
      @identity = Containment::Identity.new(MECHANISM, "#{device}:#{inode}")
      open("cgroup.type", LibC::O_RDONLY)
      type = Native.read(@descriptors["cgroup.type"], "group.open", "cgroup.type").strip
      raise Error::Unsupported.new("cgroup v2 domain required") unless type == "domain"

      open("cgroup.events", LibC::O_RDONLY)
      observe
      operations = %w(group.observe group.wait_empty)
      if open("cgroup.kill", LibC::O_WRONLY, optional: true)
        operations << "control.kill"
      end
      if open("cgroup.freeze", LibC::O_WRONLY, optional: true)
        operations.concat(%w(control.suspend control.resume))
      end
      if Native.clone_reachable? && open("cgroup.procs", LibC::O_WRONLY, optional: true)
        @birth = Containment::Birth.new(@path, device, inode)
        operations << "group.birth"
      end
      @capabilities = Capability::Snapshot.new(operations.map { |operation| Capability::Operation.new(operation) }, :delegated, MECHANISM)
    end

    def birth : Containment::Birth?
      check_context!
      @mutex.synchronize do
        return if @release || @birth_disabled || @freeze_requested || !@birth
        return if sample.frozen == true
        @birth
      end
    end

    def launcher : Spawn::Launcher?
      Platform::Unix::Launcher.default
    end

    def observe : Containment::Observation
      check_context!
      @mutex.synchronize do
        check_open!
        sample
      end
    end

    def control(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Group::Result
      check_context!
      @mutex.synchronize do
        check_open!
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          return refused(request, Error.new("cgroup control budget ended before delivery"))
        end
        case request
        when Control::Kill::Request
          return refused(request, Error::Unsupported.new("explicit exit codes are unavailable on Linux")) if request.exit_code
          stage, value = {"cgroup.kill", "1"}
        when Control::Suspend::Request
          stage, value = {"cgroup.freeze", "1"}
        when Control::Resume::Request
          stage, value = {"cgroup.freeze", "0"}
        else
          return refused(request, Error::Unsupported.new("cgroup control operation unavailable"))
        end
        unless fd = @descriptors[stage]?
          return refused(request, Error::Unsupported.new("cgroup control file unavailable"))
        end
        @birth_disabled = true if stage == "cgroup.kill"
        @freeze_requested = true if request.is_a?(Control::Suspend::Request)
        effect = Native.write(fd, value, request.operation, stage)
        @freeze_requested = false if request.is_a?(Control::Resume::Request) && effect.is_a?(Control::Report::Success)
        Control::Group::Result.new(request, ([] of Control::Result), MECHANISM, effect: effect)
      end
    rescue ex : ProcessControl::Error
      refused(request, ex)
    end

    def attach(handle : Handle::Borrowed, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Containment::Membership::Result
      request = Attach.new
      reason = Error::Unsupported.new("cgroup v2 does not provide retained-handle attachment")
      result = Control::Result.new(request, handle.identity, Control::Refused.new(reason), MECHANISM)
      Containment::Membership::Result.new(handle.identity, @identity, result)
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      return retryable_release("cgroup belongs to another process context") if Process.pid != @context
      @mutex.synchronize do
        if previous = @release
          return previous
        end
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          return retryable_release("cgroup close was not attempted within its budget")
        end

        records = @descriptors.compact_map do |name, fd|
          if LibC.close(fd) < 0
            diagnostic = Native.diagnostic("group.close", name, Errno.value)
            Control::Release::Record.new(name, :uncertain, diagnostic)
          end
        end
        @descriptors.clear
        @release = Control::Release::Result.new(records)
      end
    end

    private class Attach < Control::Request
      def operation : String
        "group.attach"
      end
    end

    private def open(name : String, flags : Int32, *, optional = false) : Bool
      if fd = Native.open_file(@directory, name, flags, optional: optional)
        @descriptors[name] = fd
        true
      else
        false
      end
    end

    private def check_context! : Nil
      raise Error::Context::Mismatch.new("cgroup belongs to another process context") unless Process.pid == @context
    end

    private def sample : Containment::Observation
      record = Native.read(@descriptors["cgroup.events"], "group.observe", "cgroup.events")
      population = Containment::Population::Unknown
      frozen = nil.as(Bool?)
      record.each_line do |line|
        case line
        when "populated 0" then population = Containment::Population::Empty
        when "populated 1" then population = Containment::Population::Populated
        when "frozen 0"    then frozen = false
        when "frozen 1"    then frozen = true
        end
      end
      if population.unknown?
        raise Error.new("cgroup population is unavailable", Diagnostic.new("group.observe", "invalid populated field", stage: "cgroup.events"))
      end
      Containment::Observation.new(@identity, population, frozen: frozen)
    end

    private def check_open! : Nil
      raise Error::Closed.new("cgroup controller is closed") if @release
    end

    private def retryable_release(message : String) : Control::Release::Result
      diagnostic = Diagnostic.new("group.close", message, stage: "before-release")
      Control::Release::Result.new([Control::Release::Record.new("cgroup v2 descriptors", :retryable, diagnostic)])
    end

    private def refused(request : Control::Request, reason : Error) : Control::Group::Result
      Control::Group::Result.new(request, ([] of Control::Result), MECHANISM, reason)
    end
  end
end
