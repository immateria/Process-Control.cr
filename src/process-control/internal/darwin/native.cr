require "./kernel/mach"

module ProcessControl::Internal::Darwin
  class Native < Driver
    def context : Int64
      Kernel::Process.pid
    end

    def available? : Bool
      Kernel::Process.signaling?
    end

    def open(pid : Int32) : Tuple(UInt32, Int32)
      unless Kernel::Process.messages?
        raise Error::Unsupported.new("direct Darwin task messages require macOS 13 or later")
      end
      Kernel::Mach.open(pid)
    end

    def read(port : UInt32) : Tuple(StaticArray(UInt32, 8), UInt32, Int32)
      Kernel::Mach.read(port)
    end

    def retain(port : UInt32) : Int32
      Kernel::Mach.retain(port)
    end

    def release(port : UInt32) : Int32
      Kernel::Mach.release(port)
    end

    def signal(token : Token, number : Int32) : Int32
      raise Error::Unsupported.new("audit-token signaling is unavailable") unless available?
      words = token.words
      Kernel::Process.signal(words.to_unsafe, number)
    end

    def open_watch : Int32
      result = Kernel.call(362)
      raise watch_error("handle.open", "open-watch", result.error.to_i64) unless result.error == 0
      result.primary.to_i32!
    end

    def register_watch(fd : Int32, pid : Int32) : Nil
      change = Event::Kevent64.new(ident: pid.to_u64, filter: Event::EVFILT_PROC,
        flags: Event::EV_ADD | Event::EV_ONESHOT, fflags: Event::NOTE_EXIT)
      result = Kernel.call(369, fd.to_u64!, pointerof(change).address, 1_u64, 0_u64, 0_u64, Event::IMMEDIATE.to_u64)
      unless result.error == 0
        raise watch_error("handle.open", "register-watch", result.error.to_i64)
      end
    end

    def watch_version(pid : Int32) : UInt32
      info = LibProc::Unique.new
      # Include an unreaped target that exited between registration and this
      # identity check. A missing or partial sample cannot bind the watch.
      result = Kernel::Process.info(pid, LibProc::PIDUNIQIDENTIFIERINFO, 1_u64, pointerof(info).as(Void*), sizeof(LibProc::Unique))
      unless result.error == 0
        raise watch_error("handle.open", "watch-identity", result.error.to_i64)
      end
      unless result.primary == sizeof(LibProc::Unique)
        raise Identity::Unverifiable.new("Darwin watch identity response has an unexpected size")
      end
      info.pid_version.to_u32!
    end

    def poll_watch(fd : Int32, pid : Int32) : Bool
      event = Event::Kevent64.new
      result = Kernel.call(369, fd.to_u64!, 0_u64, 0_u64, pointerof(event).address, 1_u64, Event::IMMEDIATE.to_u64)
      unless result.error == 0
        # Keep the event eligible for the next nonblocking sample. The caller's
        # wait loop checks its original deadline and cancellation between polls.
        return false if result.error == Errno::EINTR.value
        raise watch_error("wait.exit", "poll-watch", result.error.to_i64)
      end
      return false if result.primary == 0
      if event.flags.bits_set?(Event::EV_ERROR)
        raise watch_error("wait.exit", "event-watch", event.data)
      end
      unless event.filter == Event::EVFILT_PROC && event.ident == pid.to_u64 && event.fflags.bits_set?(Event::NOTE_EXIT)
        diagnostic = Diagnostic.new("wait.exit", "unexpected kqueue event", stage: "event-watch")
        raise Observation::Failed.new("Darwin exit watch received an unexpected event", diagnostic)
      end
      true
    end

    def close_watch(fd : Int32) : Int32
      Kernel.call(6, fd.to_u64!).error
    end

    private def watch_error(operation : String, stage : String, code : Int64) : Observation::Failed
      diagnostic = Diagnostic.new(operation, "Darwin exit watch failed", native_domain: "errno", native_code: code, stage: stage)
      Observation::Failed.new("Darwin exit watch failed at #{stage}", diagnostic)
    end
  end
end
