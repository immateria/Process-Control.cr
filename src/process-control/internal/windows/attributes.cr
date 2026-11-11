module ProcessControl::Internal::Windows
  module Attributes
    EXTENDED_STARTUPINFO_PRESENT = 0x0008_0000_u32
    private HANDLE_LIST                  = 0x0002_0002_u64
    private JOB_LIST                     = 0x0002_000d_u64

    def self.check_job(job : LibC::HANDLE) : Nil
      jobs = StaticArray[job]
      with_list(1_u32) { |attributes| assign_job(attributes, jobs.to_unsafe) }
    end

    def self.with(handles : LibC::HANDLE[3], job : LibC::HANDLE?, & : LibC::STARTUPINFOW* -> T) : T forall T
      with_list(job ? 2_u32 : 1_u32) do |attributes|
        if ABI.UpdateProcThreadAttribute(attributes, 0_u32, HANDLE_LIST, handles.to_unsafe, sizeof(LibC::HANDLE[3]).to_u64, nil, nil) == 0
          raise Windows.error("UpdateProcThreadAttribute(HANDLE_LIST)")
        end
        jobs = StaticArray[job || LibC::HANDLE.null]
        assign_job(attributes, jobs.to_unsafe) if job
        startup = ABI::Startup.new
        startup.base.cb = sizeof(ABI::Startup).to_u32
        startup.base.dwFlags = LibC::STARTF_USESTDHANDLES
        startup.base.hStdInput = handles[0]
        startup.base.hStdOutput = handles[1]
        startup.base.hStdError = handles[2]
        startup.attributes = attributes
        yield pointerof(startup).as(LibC::STARTUPINFOW*)
      end
    end

    private def self.assign_job(attributes : Void*, jobs : LibC::HANDLE*) : Nil
      if ABI.UpdateProcThreadAttribute(attributes, 0_u32, JOB_LIST, jobs, sizeof(LibC::HANDLE).to_u64, nil, nil) == 0
        code = WinError.value
        raise Error::Unsupported.new("Windows creation-time Job assignment is unavailable", Windows.diagnostic("UpdateProcThreadAttribute(JOB_LIST)", code))
      end
    end

    private def self.with_list(count : UInt32, & : Void* -> T) : T forall T
      result = ABI.InitializeProcThreadAttributeList(nil, count, 0_u32, out size)
      code = WinError.value
      unless result == 0 && code == WinError::ERROR_INSUFFICIENT_BUFFER && size > 0
        raise Windows.error("InitializeProcThreadAttributeList(size)", code)
      end

      storage = Pointer(UInt8).malloc(size)
      attributes = storage.as(Void*)
      if ABI.InitializeProcThreadAttributeList(attributes, count, 0_u32, pointerof(size)) == 0
        raise Windows.error("InitializeProcThreadAttributeList")
      end
      begin
        yield attributes
      ensure
        ABI.DeleteProcThreadAttributeList(attributes)
      end
    end
  end
end
