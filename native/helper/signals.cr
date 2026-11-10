module ProcessControl::Internal::Unix::Owner
  def self.ignore_pipe : Int32
    action = LibC::Sigaction.new
    # Materialize the native SIG_IGN function-pointer sentinel. The stdlib
    # constant needs runtime initialization, and passing a dynamic Proc through
    # FFI retains a managed closure check in unoptimized code.
    pointerof(action.@sa_sigaction).as(Pointer(Void)*).value = Pointer(Void).new(1_u64)
    LibC.sigemptyset(pointerof(action.@sa_mask))
    LibC.sigaction(LibC::SIGPIPE, pointerof(action), nil)
  end

  def self.child_failed(fd : Int32, error : Int32) : NoReturn
    loop do
      sent = LibC.write(fd, pointerof(error), 4)
      break unless sent < 0 && Errno.value == Errno::EINTR
    end
    LibC._exit(127)
  end

  def self.prepare_signals : Int32
    action = LibC::Sigaction.new
    handler = ->(_number : Int32, _info : LibC::SiginfoT*, _context : Void*) { nil }
    # This literal captures no state. Store its native function pointer without
    # the managed Proc closure check inserted by the C-struct setter.
    pointerof(action.@sa_sigaction).as(Pointer(Void)*).value = handler.pointer
    action.sa_flags = LibC::SA_SIGINFO
    LibC.sigemptyset(pointerof(action.@sa_mask))
    return -1 if LibC.sigaction(LibC::SIGCHLD, pointerof(action), nil) < 0
    mask = uninitialized LibC::SigsetT
    LibC.sigemptyset(pointerof(mask))
    Native.sigprocmask(LibC::SIG_SETMASK, pointerof(mask), nil)
  end

  def self.reset_target_signals : Int32
    mask = uninitialized LibC::SigsetT
    LibC.sigemptyset(pointerof(mask))
    return -1 if Native.sigprocmask(LibC::SIG_SETMASK, pointerof(mask), nil) < 0
    action = LibC::Sigaction.new
    LibC.sigemptyset(pointerof(action.@sa_mask))
    number = 1
    while number < SIGNALS
      if number != LibC::SIGKILL && number != LibC::SIGSTOP
        return -1 if LibC.sigaction(number, pointerof(action), nil) < 0 && Errno.value != Errno::EINVAL
      end
      number &+= 1
    end
    0
  end
end
