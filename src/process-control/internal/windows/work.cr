require "./startup"

module ProcessControl::Internal::Windows
  class Work
    include Spawn::Pending::Owner

    private CREATE_SUSPENDED = 0x0004_u32

    @stdio = Stdio.new
    @process = LibC::PROCESS_INFORMATION.new
    @control : LibC::HANDLE? = nil
    @attempted = false
    @records = [] of Control::Release::Record

    def initialize(@plan : Spawn::Plan, @capabilities : Capability::Snapshot, @job : Job? = nil, *, @driver : Startup = Startup.new)
    end

    def launch(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Spawn::Attempt::Result
      executable = @plan.executable
      unless File.extname(executable).downcase == ".exe"
        raise Error::Unsupported.new("Windows launch requires an explicit native executable")
      end
      application = executable.to_utf16
      if LibC.GetBinaryTypeW(application, out _) == 0
        raise Windows.error("GetBinaryTypeW")
      end
      command = ::Process.quote_windows([executable] + @plan.args).to_utf16
      if command.size >= 32_767
        raise Error.new("Windows command line exceeds 32767 UTF-16 code units")
      end
      environment = Environment.block(@plan.environment)
      directory = @plan.directory.to_utf16
      handles = @stdio.prepare(@plan.stdio)
      if job = @job
        job.with_handle do |handle|
          create(application, command, environment, directory, handles, handle, deadline, cancel)
        end
      else
        create(application, command, environment, directory, handles, nil, deadline, cancel)
      end
      close_temporaries
      raise Error::Ownership.new("Windows inherited-handle cleanup is uncertain") if @records.any? { |record| !record.state.complete? }
      identity = @driver.identify(@process.hProcess, @process.dwProcessId)
      control = @control = @driver.duplicate(@process.hProcess)
      authority = Authority.new(control, identity, @capabilities)
      source = Spawn::Status::Source.new(identity)
      case count = @driver.resume(@process.hThread)
      when 1_u32
      when UInt32::MAX
        raise @driver.error("ResumeThread")
      else
        raise Error.new("Windows child had unexpected suspend count #{count}")
      end
      close_thread
      raise Error::Ownership.new("Windows launch cleanup is uncertain") if @records.any? { |record| !record.state.complete? }

      streams = @stdio.endpoints
      registration = Spawn::Registration.new(authority, source, streams)
      native = @process.hProcess
      spawn(name: "process-control-windows-status") { Status.collect(native, source) }
      @process.hProcess = LibC::HANDLE.null
      @control = nil
      Spawn::Attempt::Registered.new(registration)
    rescue ex : ProcessControl::Error
      rollback(ex)
    rescue ex : IO::Error | RuntimeError
      rollback(Windows.setup_error("windows.spawn", "setup", ex))
    end

    private def create(application, command, environment, directory, handles, job, deadline, cancel) : Nil
      Attributes.with(handles, job) do |startup|
        if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
          raise Error.new("spawn cancelled or expired before creation")
        end
        @attempted = true
        flags = CREATE_SUSPENDED | LibC::CREATE_UNICODE_ENVIRONMENT | Attributes::EXTENDED_STARTUPINFO_PRESENT
        if LibC.CreateProcessW(application, command, nil, nil, true, flags, environment, directory, startup, pointerof(@process)) == 0
          raise Windows.error("CreateProcessW")
        end
      end
    end

    private def close_temporaries : Nil
      @records.concat(@stdio.close_temporaries)
    end

    private def close_thread : Nil
      return if @process.hThread.null?
      @records << @driver.close(@process.hThread, "Windows primary thread")
      @process.hThread = LibC::HANDLE.null
    end

    private def rollback(error : ProcessControl::Error) : Spawn::Attempt::Result
      close_temporaries
      @records.concat(@stdio.close_parents)
      close_thread
      if control = @control
        @records << @driver.close(control, "Windows control handle")
        @control = nil
      end

      native = @process.hProcess
      if native.null?
        cleanup = Control::Release::Result.new(@records)
        return Spawn::Attempt::Rejected.new(error, cleanup, @attempted) if cleanup.complete?
        return Spawn::Attempt::Pending.new(unresolved(error, cleanup), wait: false)
      end

      if @driver.wait(native) == LibC::WAIT_OBJECT_0
        @records << @driver.close(native, "Windows startup process handle")
        @process.hProcess = LibC::HANDLE.null
        cleanup = Control::Release::Result.new(@records)
        return Spawn::Attempt::Rejected.new(error, cleanup, true) if cleanup.complete?
        return Spawn::Attempt::Pending.new(unresolved(error, cleanup), wait: false)
      end

      pending = unresolved(error, Control::Release::Result.new(@records + [
        Control::Release::Record.new("Windows startup process", :retryable),
      ]))
      unless @driver.terminate(native)
        pending.note(@driver.diagnostic("TerminateProcess(startup cleanup)"))
      end
      spawn(name: "process-control-windows-startup-cleanup") { settle(pending, error) }
      Spawn::Attempt::Pending.new(pending, wait: false)
    end

    private def settle(pending : Spawn::Pending, error : ProcessControl::Error) : Nil
      native = @process.hProcess
      loop do
        case @driver.wait(native)
        when LibC::WAIT_OBJECT_0
          @records << @driver.close(native, "Windows startup process handle")
          @process.hProcess = LibC::HANDLE.null
          cleanup = Control::Release::Result.new(@records)
          pending.note_cleanup(cleanup)
          pending.publish(Spawn::Rejected.new(error, cleanup, attempted: true)) if cleanup.complete?
          return
        when LibC::WAIT_TIMEOUT
          sleep 5.milliseconds
        else
          detail = @driver.diagnostic("WaitForSingleObject(startup cleanup)")
          pending.note(detail)
          pending.note_cleanup(Control::Release::Result.new(@records + [
            Control::Release::Record.new("Windows startup process", :uncertain, detail),
          ]))
          return
        end
      end
    end

    private def unresolved(error : ProcessControl::Error, cleanup : Control::Release::Result) : Spawn::Pending
      pending = Spawn::Pending.new(error.diagnostic || ProcessControl::Diagnostic.new("windows.spawn", error.message || "launch failed"))
      pending.note_cleanup(cleanup)
      pending.retain(self)
      pending
    end
  end
end
