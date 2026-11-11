module Fixture::Windows
  class Startup < PC::Internal::Windows::Startup
    getter calls = Hash(Symbol, Int32).new(0)
    @process : LibC::HANDLE? = nil
    @observer : LibC::HANDLE? = nil
    @process_closed = false

    def initialize(@failure : Symbol)
    end

    def identify(handle : LibC::HANDLE, pid : Int) : PC::Identity
      @calls[:identify] += 1
      @process = handle
      # A fixture-owned reference permits safe teardown without borrowing the
      # failed launch owner's authority or reopening the numeric PID.
      @observer = PC::Internal::Windows.duplicate(handle)
      if @failure.in?(:identify, :terminate, :wait)
        raise error("GetProcessTimes")
      end
      super
    end

    def duplicate(handle : LibC::HANDLE) : LibC::HANDLE
      @calls[:duplicate] += 1
      raise error("DuplicateHandle") if @failure == :duplicate
      super
    end

    def resume(thread : LibC::HANDLE) : UInt32
      @calls[:resume] += 1
      return UInt32::MAX if @failure == :resume
      super
    end

    def wait(handle : LibC::HANDLE) : UInt32
      @calls[:wait] += 1
      return UInt32::MAX if @failure == :wait && @calls[:wait] > 1
      super
    end

    def terminate(handle : LibC::HANDLE) : Bool
      @calls[:terminate] += 1
      return false if @failure == :terminate
      super
    end

    def close(handle : LibC::HANDLE, resource : String) : PC::Control::Release::Record
      key = case resource
            when "Windows primary thread"         then :close_thread
            when "Windows control handle"         then :close_control
            when "Windows startup process handle" then :close_process
            else                                       raise "unexpected startup resource #{resource}"
            end
      @calls[key] += 1
      record = super
      @process_closed = record.state.complete? if key == :close_process
      if @failure == :close && key == :close_thread
        # Simulate failure after the native effect. The owner must retain the
        # uncertainty and must never replay this CloseHandle operation.
        record.state.complete?.should be_true
        return PC::Control::Release::Record.new(resource, :uncertain, diagnostic("CloseHandle"))
      end
      record
    end

    def diagnostic(operation : String) : PC::Diagnostic
      PC::Internal::Windows.diagnostic(operation, WinError::ERROR_ACCESS_DENIED)
    end

    def error(operation : String) : PC::Error
      PC::Internal::Windows.error(operation, WinError::ERROR_ACCESS_DENIED)
    end

    def alive? : Bool
      LibC.WaitForSingleObject(@observer.not_nil!, 0_u32) == LibC::WAIT_TIMEOUT
    end

    def terminate_fixture : Nil
      handle = @observer.not_nil!
      if LibC.WaitForSingleObject(handle, 0_u32) == LibC::WAIT_TIMEOUT
        LibC.TerminateProcess(handle, 71_u32).should_not eq(0)
      end
      deadline = PC::Wait::Deadline.after(5.seconds)
      until LibC.WaitForSingleObject(handle, 0_u32) == LibC::WAIT_OBJECT_0
        raise "fixture process did not terminate" if deadline.expired?
        deadline.pause
      end
    end

    def dispose : Nil
      if observer = @observer
        terminate_fixture
        # A failed observation makes the background cleanup stop. Its retained
        # handle is released only by this fixture's out-of-band teardown.
        if @failure == :wait && !@process_closed
          LibC.CloseHandle(@process.not_nil!).should_not eq(0)
          @process_closed = true
        end
        LibC.CloseHandle(observer).should_not eq(0)
        @observer = nil
      end
    end
  end

  def self.handle_count : UInt32
    count = 0_u32
    WindowsSpec.GetProcessHandleCount(LibC.GetCurrentProcess, pointerof(count)).should_not eq(0)
    count
  end
end
