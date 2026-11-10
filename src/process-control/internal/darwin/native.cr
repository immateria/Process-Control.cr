require "c/dlfcn"

module ProcessControl::Internal::Darwin
  class Native < Driver
    alias Function = (Pointer(UInt32), Int32 -> Int32)

    @mutex = Mutex.new
    @library = Pointer(Void).null
    @function : Function? = nil

    def available? : Bool
      !function.nil?
    end

    def open(pid : Int32) : Tuple(UInt32, Int32)
      port = 0_u32
      code = ABI.task_name_for_pid(ABI.mach_task_self_, pid, pointerof(port))
      {port, code}
    end

    def read(port : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
      words = StaticArray(UInt32, 8).new(0_u32)
      count = 8_u32
      code = ABI.task_info(port, ABI::TASK_AUDIT_TOKEN, words.to_unsafe.as(Pointer(Int32)), pointerof(count))
      {words, count, code}
    end

    def retain(port : UInt32) : Int32
      ABI.mach_port_mod_refs(ABI.mach_task_self_, port, ABI::MACH_PORT_RIGHT_SEND, 1)
    end

    def release(port : UInt32) : Int32
      ABI.mach_port_deallocate(ABI.mach_task_self_, port)
    end

    def signal(token : Token, number : Int32) : Int32
      call = function || raise Error::Unsupported.new("audit-token signaling is unavailable")
      words = token.words
      call.call(words.to_unsafe, number)
    end

    private def function : Function?
      @mutex.synchronize do
        return @function if @function
        if @library.null?
          @library = LibC.dlopen("/usr/lib/libproc.dylib", LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
          return nil if @library.null?
        end
        symbol = LibC.dlsym(@library, "proc_signal_with_audittoken")
        return nil if symbol.null?
        # Keep the system image referenced for the lifetime of these pointers.
        @function = Function.new(symbol, Pointer(Void).null)
      end
    end
  end
end
