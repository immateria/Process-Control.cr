module ProcessControl::Internal::Unix::Owner::System
  def self.signal_action(signal : Int32, handler : UInt64, trampoline : UInt64 = 0_u64,
                         flags : Int32 = 0, mask : UInt32 = 0_u32) : Int32
    action = ::Native::Kernel::Darwin::Signal::Action.new(handler, trampoline, mask, flags | 0x0400)
    value(::Native::Kernel::Darwin::Signal.action(signal, pointerof(action))).to_i32!
  end

  def self.clear_signal_mask : Int32
    mask = 0_u32
    value(::Native::Kernel::Darwin::Signal.mask(3, pointerof(mask), Pointer(UInt32).null)).to_i32!
  end

  def self.sigreturn(context : Void*, style : Int32, token : UInt64) : NoReturn
    ::Native::Kernel::Darwin::Signal.restore(context, style, token)
    exit(126)
  end
end

module ProcessControl::Internal::Unix::Owner
  def self.ignore_pipe : Int32
    System.signal_action(13, 1_u64)
  end

  def self.prepare_signals : Int32
    # The handler needs no action. The trampoline restores the exact interrupted
    # context through sigreturn and supplies its kernel-issued validation token.
    trampoline = ->(_handler : Void*, style : Int32, _signal : Int32, _info : Void*, context : Void*, token : UInt64) {
      System.sigreturn(context, style, token)
    }
    function = trampoline.pointer.address
    result = System.signal_action(20, function, function, 0x40)
    return result if result < 0
    System.clear_signal_mask
  end

  def self.reset_target_signals : Int32
    result = System.clear_signal_mask
    return result if result < 0
    signal = 1
    while signal < SIGNALS
      if signal != 9 && signal != 17
        result = System.signal_action(signal, 0_u64)
        return result if result < 0 && result != -22
      end
      signal &+= 1
    end
    0
  end

  def self.child_failed(fd : Int32, error : Int32, stage : Int32) : NoReturn
    failure = uninitialized Int32[2]
    failure.to_unsafe[0] = error
    failure.to_unsafe[1] = stage
    loop do
      sent = System.write(fd, failure.to_unsafe, 8_u64)
      break unless sent == -4
    end
    System.exit(127)
  end
end
