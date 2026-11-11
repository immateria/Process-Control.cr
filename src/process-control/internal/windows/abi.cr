module ProcessControl::Internal::Windows
  lib ABI
    struct Startup
      base : LibC::STARTUPINFOW
      attributes : Void*
    end

    fun InitializeProcThreadAttributeList(list : Void*, count : UInt32, flags : UInt32, size : LibC::SizeT*) : LibC::BOOL
    fun UpdateProcThreadAttribute(list : Void*, flags : UInt32, attribute : LibC::SizeT, value : Void*,
                                  size : LibC::SizeT, previous : Void*, return_size : LibC::SizeT*) : LibC::BOOL
    fun DeleteProcThreadAttributeList(list : Void*) : Void

    fun ResumeThread(thread : LibC::HANDLE) : LibC::DWORD

    fun CompareStringOrdinal(left : UInt16*, left_length : Int32, right : UInt16*, right_length : Int32, ignore_case : LibC::BOOL) : Int32
  end
end
