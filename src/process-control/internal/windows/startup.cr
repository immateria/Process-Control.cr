module ProcessControl::Internal::Windows
  # The startup owner keeps these operations together so failure handling can
  # be exercised at each boundary after a real suspended process is created.
  class Startup
    def identify(handle : LibC::HANDLE, pid : Int) : ProcessControl::Identity
      Windows.identify(handle, pid)
    end

    def duplicate(handle : LibC::HANDLE) : LibC::HANDLE
      Windows.duplicate(handle)
    end

    def resume(thread : LibC::HANDLE) : UInt32
      ABI.ResumeThread(thread)
    end

    def wait(handle : LibC::HANDLE) : UInt32
      LibC.WaitForSingleObject(handle, 0_u32)
    end

    def terminate(handle : LibC::HANDLE) : Bool
      LibC.TerminateProcess(handle, 1_u32) != 0
    end

    def close(handle : LibC::HANDLE, resource : String) : Control::Release::Record
      Windows.close(handle, resource)
    end

    def diagnostic(operation : String) : ProcessControl::Diagnostic
      Windows.diagnostic(operation)
    end

    def error(operation : String) : ProcessControl::Error
      Windows.error(operation)
    end
  end
end
