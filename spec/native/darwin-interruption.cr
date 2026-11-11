# Build with -Dwithout_main. This fixture owns and collects each native child.
{% unless flag?(:darwin) %}
  {% raise "The interruption fixture requires Darwin." %}
{% end %}

require "../../native/helper/protocol"
require "../../native/helper/darwin"

module Fixture::Darwin::Interruption
  alias Kernel = ::Native::Kernel::Darwin::Raw
  alias System = ProcessControl::Internal::Unix::Owner::System
  alias Frame = ProcessControl::Internal::Unix::Owner::Frame

  module Native
    struct Kevent64
      property ident : UInt64
      property filter : Int16
      property flags : UInt16
      property fflags : UInt32
      property data : Int64
      property udata : UInt64
      property ext : StaticArray(UInt64, 2)

      def initialize(@ident = 0_u64, @filter = 0_i16, @flags = 0_u16,
                     @fflags = 0_u32, @data = 0_i64, @udata = 0_u64,
                     @ext = StaticArray(UInt64, 2).new(0_u64))
      end
    end

    struct Report
      property calls = 0_u64
      property empty = 0_u64
      property exits = 0_u64
      property interrupted = 0_u64
      property unexpected = 0_u64
      property signals = 0_i64
      property sender = 0
      property target = 0
      property blocking_result = 0
      property blocking_errno = 0
      property post_exits = 0_u64
      property post_sender = 0
      property post_target = 0
    end

    struct Timespec
      @seconds : Int64
      @nanoseconds : Int64

      def initialize(@seconds = 0_i64, @nanoseconds = 0_i64)
      end
    end
  end

  def self.poll_event(fd : Int32, changes : Native::Kevent64*, nchanges : Int32,
                      events : Native::Kevent64*, nevents : Int32, flags : UInt32,
                      timeout : Native::Timespec* = Pointer(Native::Timespec).null) : ::Native::Kernel::Darwin::Result
    Kernel.call(369, fd.to_u64!, changes.address, nchanges.to_u64!, events.address,
      nevents.to_u64!, flags.to_u64!, timeout.address)
  end

  def self.collect(pid : Int32, expected : Int32) : Bool
    status = 0
    result = System.waitpid(pid, pointerof(status), 0)
    while result == -4
      result = System.waitpid(pid, pointerof(status), 0)
    end
    result == pid && status == expected &* 256
  end

  def self.discard(pid : Int32) : Nil
    return if pid <= 0
    System.kill(pid, 9)
    status = 0
    while System.waitpid(pid, pointerof(status), 0) == -4
    end
  end

  def self.child(delay : UInt32, code : Int32) : Int32
    target = System.fork
    if target == 0
      System.sleep(delay)
      System.exit(code)
    end
    target
  end

  def self.watch(pid : Int32) : Int32
    queue = Kernel.call(362)
    fd = queue.error == 0 ? queue.primary.to_i32! : (0_i32 &- queue.error)
    return -1 if fd < 0
    change = Native::Kevent64.new(ident: pid.to_u64!, filter: -5_i16,
      flags: 0x11_u16, fflags: 0x80000000_u32)
    if poll_event(fd, pointerof(change), 1, Pointer(Native::Kevent64).null, 0, 1_u32).error != 0
      System.close(fd)
      return -1
    end
    fd
  end

  def self.sender(parent : Int32, count : Int32, delay : UInt32) : Int32
    pid = System.fork
    if pid == 0
      System.sleep(delay)
      i = 0
      while i < count && System.parent == parent
        System.kill(parent, 30)
        System.sleep(5_u32)
        i &+= 1
      end
      System.exit(0)
    end
    pid
  end

  def self.immediate(report : Native::Report*) : Int32
    data = report.value
    target = child(200_000_u32, 23)
    return 11 if target < 0
    fd = watch(target)
    if fd < 0
      discard(target)
      return 12
    end
    sender = sender(System.pid, 20_000, 10_000_u32)
    if sender < 0
      System.close(fd)
      discard(target)
      return 13
    end

    before_signals = System.seek(2, 0, 1)
    i = 0_u64
    while i < 2_000_000_u64
      event = Native::Kevent64.new
      # These are the production poll_watch arguments, including IMMEDIATE.
      # XNU 11417.101.15 kqueue_scan returns before its abort-safe wait for this
      # flag. Its blocking counterpart below supplies the native EINTR control.
      result = poll_event(fd, Pointer(Native::Kevent64).null, 0, pointerof(event), 1, 1_u32)
      count = result.primary
      if count == 0
        data.empty &+= 1
      elsif count == 1 && event.filter == -5 && event.ident == target.to_u64! && event.fflags == 0x80000000_u32
        data.exits &+= 1
      elsif count < 0 && result.error == 4
        data.interrupted &+= 1
      else
        data.unexpected &+= 1
      end
      i &+= 1
    end
    data.calls = i
    data.signals = System.seek(2, 0, 1) &- before_signals
    data.sender = collect(sender, 0) ? 1 : 0
    data.target = collect(target, 23) ? 1 : 0
    System.close(fd)
    report.value = data
    0
  end

  def self.blocking(report : Native::Report*) : Int32
    data = report.value
    target = child(500_000_u32, 37)
    return 15 if target < 0
    fd = watch(target)
    if fd < 0
      discard(target)
      return 16
    end
    sender = sender(System.pid, 1, 20_000_u32)
    if sender < 0
      System.close(fd)
      discard(target)
      return 17
    end
    event = Native::Kevent64.new
    timeout = Native::Timespec.new(1_i64, 0_i64)
    # A positive control establishes real signal interruption on this kernel.
    # It deliberately enables waiting, unlike the production IMMEDIATE poll.
    result = poll_event(fd, Pointer(Native::Kevent64).null, 0, pointerof(event), 1, 0_u32, pointerof(timeout))
    data.blocking_result = result.primary.to_i32!
    data.blocking_errno = result.error
    data.post_sender = collect(sender, 0) ? 1 : 0
    i = 0
    while i < 20_000
      result = poll_event(fd, Pointer(Native::Kevent64).null, 0, pointerof(event), 1, 1_u32)
      count = result.primary
      if count == 1
        if event.filter == -5 && event.ident == target.to_u64! && event.fflags == 0x80000000_u32
          data.post_exits &+= 1
        else
          data.unexpected &+= 1
        end
        break
      elsif count < 0 && result.error != 4
        data.unexpected &+= 1
        break
      end
      System.sleep(50_u32)
      i &+= 1
    end
    data.post_target = collect(target, 37) ? 1 : 0
    System.close(fd)
    report.value = data
    0
  end

  def self.run : Int32
    trampoline = ->(_handler : Void*, style : Int32, _signal : Int32, _info : Void*, context : Void*, token : UInt64) {
      byte = 1_u8
      System.write(2, pointerof(byte), 1_u64)
      System.sigreturn(context, style, token)
    }
    function = trampoline.pointer.address
    return 10 if System.signal_action(30, function, function, 0x40) < 0

    report = Native::Report.new
    error = immediate(pointerof(report))
    return error unless error == 0
    error = blocking(pointerof(report))
    return error unless error == 0
    bytes = uninitialized UInt8[1024]
    frame = Frame.new(bytes.to_unsafe, 1024)
    return 19 unless frame.text("{\"calls\":".to_unsafe) && frame.integer(report.calls) &&
                     frame.text(",\"empty\":".to_unsafe) && frame.integer(report.empty) &&
                     frame.text(",\"exits\":".to_unsafe) && frame.integer(report.exits) &&
                     frame.text(",\"eintr\":".to_unsafe) && frame.integer(report.interrupted) &&
                     frame.text(",\"unexpected\":".to_unsafe) && frame.integer(report.unexpected) &&
                     frame.text(",\"signals\":".to_unsafe) && frame.signed(report.signals.to_i64) &&
                     frame.text(",\"sender\":".to_unsafe) && frame.signed(report.sender.to_i64) &&
                     frame.text(",\"target\":".to_unsafe) && frame.signed(report.target.to_i64) &&
                     frame.text(",\"blocking_result\":".to_unsafe) && frame.signed(report.blocking_result.to_i64) &&
                     frame.text(",\"blocking_errno\":".to_unsafe) && frame.signed(report.blocking_errno.to_i64) &&
                     frame.text(",\"post_exits\":".to_unsafe) && frame.integer(report.post_exits) &&
                     frame.text(",\"post_sender\":".to_unsafe) && frame.signed(report.post_sender.to_i64) &&
                     frame.text(",\"post_target\":".to_unsafe) && frame.signed(report.post_target.to_i64) &&
                     frame.text("}\n".to_unsafe)
    return 20 if ProcessControl::Internal::Unix::Owner.send_line(1, bytes.to_unsafe) < 0
    0
  end
end

fun main(argc : Int32, argv : UInt8**) : Int32
  ProcessControl::Internal::Unix::Owner::System.exit(Fixture::Darwin::Interruption.run)
end
