module ProcessControl::Internal::Unix::Owner
  def self.run(argc : Int32, argv : UInt8**) : Int32
    command, cgroup = command_layout(argc, argv)
    return 64 if command < 0
    return 65 if close_foreign < 0
    address = LibC::SockaddrUn.new
    address.sun_family = LibC::AF_UNIX
    length = Text.size(argv[1], sizeof(typeof(address.sun_path)))
    return 66 if length < 0
    path = pointerof(address.@sun_path).as(UInt8*)
    offset = 0
    while offset < length
      path[offset] = argv[1][offset]
      offset &+= 1
    end
    path[length] = 0_u8
    connection = LibC.socket(LibC::AF_UNIX, LibC::SOCK_STREAM, 0)
    return 67 if connection < 0 || cloexec(connection) < 0
    return 68 if LibC.connect(connection, pointerof(address).as(LibC::Sockaddr*), sizeof(LibC::SockaddrUn)) < 0
    return 71 if ignore_pipe < 0

    line = uninitialized UInt8[192]
    hello = Frame.new(line.to_unsafe, 192)
    return 69 unless hello.text("HELLO 2 ".to_unsafe) && hello.text(argv[2]) && hello.text(" ".to_unsafe) &&
                     hello.integer(SIGNALS.to_u64!) && hello.text(" ".to_unsafe) &&
                     hello.integer(DUPLICATE.to_u64!) && hello.text("\n".to_unsafe)
    return 70 if send_line(connection, line.to_unsafe) < 0
    expected = uninitialized UInt8[96]
    start = Frame.new(expected.to_unsafe, 96)
    return 69 unless start.text("START ".to_unsafe) && start.text(argv[2])
    return 0 if read_line(connection, line.to_unsafe, 192) < 0 || !Text.equal(line.to_unsafe, expected.to_unsafe)
    return 71 if prepare_signals < 0

    descriptors = uninitialized Int32[2]
    return 73 if LibC.pipe(descriptors) < 0
    return 74 if cloexec(descriptors.to_unsafe[0]) < 0 || cloexec(descriptors.to_unsafe[1]) < 0
    target = 0
    {% if flag?(:linux) %}
      if cgroup != 0
        fd = open_cgroup(argv[cgroup &+ 1], argv[cgroup &+ 2], argv[cgroup &+ 3])
        if fd < 0
          report(connection, "SETUP ".to_unsafe, argv[2], Errno.value.value.to_u64!)
          return 0
        end
        target = clone_into_cgroup(fd)
      else
        target = LibC.fork
      end
    {% else %}
      target = LibC.fork
    {% end %}
    if target < 0
      error = Errno.value.value
      LibC.close(descriptors.to_unsafe[0])
      LibC.close(descriptors.to_unsafe[1])
      report(connection, "CREATION ".to_unsafe, argv[2], error.to_u64!)
      return 0
    end
    if target == 0
      LibC.close(descriptors.to_unsafe[0])
      child_failed(descriptors.to_unsafe[1], Errno.value.value, 1) if reset_target_signals < 0 || setup(argv, command) < 0
      Native.execv(argv[command], argv + command)
      child_failed(descriptors.to_unsafe[1], Errno.value.value, 0)
    end
    LibC.close(descriptors.to_unsafe[1])
    failure = uninitialized Int32[2]
    received = 0_i64
    loop do
      received = LibC.read(descriptors.to_unsafe[0], failure.to_unsafe, 8)
      break unless received < 0 && Errno.value == Errno::EINTR
    end
    LibC.close(descriptors.to_unsafe[0])
    fd = 0
    while fd <= 2
      LibC.close(fd) unless fd == connection
      fd &+= 1
    end
    if received != 0
      status = uninitialized Int32
      loop do
        collected = LibC.waitpid(target, pointerof(status), 0)
        break unless collected < 0 && Errno.value == Errno::EINTR
      end
      error = received == 8 ? failure.to_unsafe[0] : Errno::EIO.value
      verb = received == 8 && failure.to_unsafe[1] == 1 ? "SETUP ".to_unsafe : "REJECTED ".to_unsafe
      report(connection, verb, argv[2], error.to_u64!)
      return 0
    end
    connected = report(connection, "STARTED ".to_unsafe, argv[2], target.to_u64!) == 0
    loop do
      status = 0
      collected = LibC.waitpid(target, pointerof(status), connected ? LibC::WNOHANG : 0)
      next if collected < 0 && Errno.value == Errno::EINTR
      if collected == target
        report_exit(connection, argv[2], status) if connected
        return 0
      end
      if collected < 0
        error = Errno.value.value
        report(connection, "FAILED ".to_unsafe, argv[2], error.to_u64!) if connected
        return 75
      end
      next unless connected
      event = Native::Event.new(fd: connection, events: 1_i16, revents: 0_i16)
      ready = Native.poll(pointerof(event), 1, 20)
      next if ready < 0 && Errno.value == Errno::EINTR
      next if ready == 0
      if ready < 0 || read_line(connection, line.to_unsafe, 192) < 0
        LibC.close(connection)
        connected = false
        next
      end
      sequence = uninitialized UInt64
      signal = uninitialized Int32
      parsed = request(line.to_unsafe, argv[2], pointerof(sequence), pointerof(signal))
      if parsed < 0
        LibC.close(connection)
        connected = false
        next
      end
      next if parsed == 0
      # Only this loop reaps. An exit racing kill remains an unreaped child;
      # after collection above we return without another signal operation.
      error = LibC.kill(target, signal) == 0 ? 0 : Errno.value.value
      reply = Frame.new(line.to_unsafe, 192)
      return 76 unless reply.text("ACK ".to_unsafe) && reply.text(argv[2]) && reply.text(" ".to_unsafe) &&
                       reply.integer(sequence) && reply.text(" ".to_unsafe) && reply.integer(error.to_u64!) && reply.text("\n".to_unsafe)
      if send_line(connection, line.to_unsafe) < 0
        LibC.close(connection)
        connected = false
      end
    end
  end
end
