module ProcessControl::Internal::Unix::Owner
  def self.run(argc : Int32, argv : UInt8**, environment : UInt8**) : Int32
    command = command_layout(argc, argv)
    return 64 if command < 0
    return 65 if close_foreign < 0
    return 66 if Text.size(argv[1], 104) < 0
    connection = System.socket
    return 67 if connection < 0 || cloexec(connection) < 0
    return 68 if System.connect(connection, argv[1]) < 0
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
    return 73 if System.pipe(descriptors.to_unsafe) < 0
    return 74 if cloexec(descriptors.to_unsafe[0]) < 0 || cloexec(descriptors.to_unsafe[1]) < 0
    target = System.fork
    if target < 0
      error = 0_i32 &- target
      System.close(descriptors.to_unsafe[0])
      System.close(descriptors.to_unsafe[1])
      report(connection, "CREATION ".to_unsafe, argv[2], error.to_u64!)
      return 0
    end
    if target == 0
      System.close(descriptors.to_unsafe[0])
      result = reset_target_signals
      child_failed(descriptors.to_unsafe[1], 0_i32 &- result, 1) if result < 0
      result = setup(argv, command)
      child_failed(descriptors.to_unsafe[1], 0_i32 &- result, 1) if result < 0
      result = System.execve(argv[command], argv + command, environment)
      child_failed(descriptors.to_unsafe[1], 0_i32 &- result, 0)
    end
    System.close(descriptors.to_unsafe[1])
    failure = uninitialized Int32[2]
    received = 0_i64
    loop do
      received = System.read(descriptors.to_unsafe[0], failure.to_unsafe, 8_u64)
      break unless received == -4
    end
    System.close(descriptors.to_unsafe[0])
    fd = 0
    while fd <= 2
      System.close(fd) unless fd == connection
      fd &+= 1
    end
    if received != 0
      status = 0
      loop do
        collected = System.waitpid(target, pointerof(status), 0)
        break unless collected == -4
      end
      error = received == 8 ? failure.to_unsafe[0] : 5
      verb = received == 8 && failure.to_unsafe[1] == 1 ? "SETUP ".to_unsafe : "REJECTED ".to_unsafe
      report(connection, verb, argv[2], error.to_u64!)
      return 0
    end
    connected = report(connection, "STARTED ".to_unsafe, argv[2], target.to_u64!) == 0
    loop do
      status = 0
      usage = uninitialized System::Native::Resource::Usage
      collected = System.wait4(target, pointerof(status), connected ? 1 : 0, pointerof(usage))
      next if collected == -4
      if collected == target
        report_exit(connection, argv[2], status, pointerof(usage)) if connected
        return 0
      end
      if collected < 0
        error = 0_i32 &- collected
        report(connection, "FAILED ".to_unsafe, argv[2], error.to_u64!) if connected
        return 75
      end
      next unless connected
      ready = System.poll(connection, 20)
      next if ready == -4
      next if ready == 0
      if ready < 0 || read_line(connection, line.to_unsafe, 192) < 0
        System.close(connection)
        connected = false
        next
      end
      sequence = 0_u64
      signal = 0
      parsed = request(line.to_unsafe, argv[2], pointerof(sequence), pointerof(signal))
      if parsed < 0
        System.close(connection)
        connected = false
        next
      end
      next if parsed == 0
      # This collector signals only while its child remains unreaped.
      result = System.kill(target, signal)
      error = result == 0 ? 0 : 0_i32 &- result
      reply = Frame.new(line.to_unsafe, 192)
      return 76 unless reply.text("ACK ".to_unsafe) && reply.text(argv[2]) && reply.text(" ".to_unsafe) &&
                       reply.integer(sequence) && reply.text(" ".to_unsafe) && reply.integer(error.to_u64!) && reply.text("\n".to_unsafe)
      if send_line(connection, line.to_unsafe) < 0
        System.close(connection)
        connected = false
      end
    end
  end
end
