require "c/handleapi"
require "c/processthreadsapi"
require "c/synchapi"
require "c/winbase"

module ProcessControl::Internal::Windows
  extend self

  QUERY     =      0x1000_u32 # PROCESS_QUERY_LIMITED_INFORMATION
  WAIT      = 0x0010_0000_u32 # SYNCHRONIZE
  TERMINATE =      0x0001_u32 # PROCESS_TERMINATE

  def diagnostic(operation : String, code = WinError.value) : ProcessControl::Diagnostic
    ProcessControl::Diagnostic.new(operation, code.message, native_domain: "win32", native_code: code.value.to_i64)
  end

  def error(operation : String, code = WinError.value) : ProcessControl::Error
    detail = diagnostic(operation, code)
    case code
    when WinError::ERROR_ACCESS_DENIED
      ProcessControl::Error::Access::Denied.new("Windows #{operation} denied", detail)
    when WinError::ERROR_FILE_NOT_FOUND, WinError::ERROR_PATH_NOT_FOUND
      ProcessControl::Error::Missing.new("Windows #{operation} could not find its target", detail)
    else
      ProcessControl::Error.new("Windows #{operation} failed", detail)
    end
  end

  def setup_error(operation : String, stage : String, cause : Exception) : ProcessControl::Error
    message = cause.message || cause.class.name
    code = case cause
           when IO::Error    then cause.os_error
           when RuntimeError then cause.os_error
           end
    detail = case code
             when WinError
               ProcessControl::Diagnostic.new(operation, message, native_domain: "win32", native_code: code.value.to_i64, stage: stage)
             when Errno
               ProcessControl::Diagnostic.new(operation, message, native_domain: "errno", native_code: code.value.to_i64, stage: stage)
             else
               ProcessControl::Diagnostic.new(operation, message, stage: stage)
             end
    ProcessControl::Error.new("Windows child setup failed: #{message}", detail)
  end

  def identify(handle : LibC::HANDLE, pid : Int) : ProcessControl::Identity
    if LibC.GetProcessTimes(handle, out created, out _, out _, out _) == 0
      raise error("GetProcessTimes")
    end
    ticks = (created.dwHighDateTime.to_u64 << 32) | created.dwLowDateTime.to_u64
    ProcessControl::Identity.new(pid, generation: ProcessControl::Identity::Generation.new("windows.creation.filetime", ticks.to_s))
  end

  def duplicate(handle : LibC::HANDLE, *, inheritable : Bool = false) : LibC::HANDLE
    current = LibC.GetCurrentProcess
    if LibC.DuplicateHandle(current, handle, current, out copy, 0_u32, inheritable, LibC::DUPLICATE_SAME_ACCESS) == 0
      raise error("DuplicateHandle")
    end
    copy
  end

  def close(handle : LibC::HANDLE, resource : String) : Control::Release::Record
    if LibC.CloseHandle(handle) == 0
      Control::Release::Record.new(resource, :uncertain, diagnostic("CloseHandle"))
    else
      Control::Release::Record.new(resource, :complete)
    end
  end

  def release(handle : LibC::HANDLE, resource : String, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
    record = if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
               detail = ProcessControl::Diagnostic.new("CloseHandle", "native release was not attempted within its budget", stage: "before-release")
               Control::Release::Record.new(resource, :retryable, detail)
             else
               close(handle, resource)
             end
    Control::Release::Result.new([record])
  end

  def observe(handle : LibC::HANDLE, identity : ProcessControl::Identity) : ProcessControl::Observation
    case LibC.WaitForSingleObject(handle, 0_u32)
    when LibC::WAIT_TIMEOUT
      ProcessControl::Observation.new(identity, presence: :present, termination: :alive)
    when LibC::WAIT_OBJECT_0
      if LibC.GetExitCodeProcess(handle, out code) == 0
        ProcessControl::Observation.new(identity, presence: :present, termination: :terminated, diagnostic: diagnostic("GetExitCodeProcess"))
      else
        info = Wait::Exit::Info.new(:windows, code, :exited, code)
        ProcessControl::Observation.new(identity, presence: :present, termination: :terminated, exit_info: info)
      end
    else
      ProcessControl::Observation.new(identity, diagnostic: diagnostic("WaitForSingleObject"))
    end
  end
end
