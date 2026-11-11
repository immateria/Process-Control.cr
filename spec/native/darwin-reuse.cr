# Build with -Dwithout_main. One native child is alive at a time.
# The parent alone reaps it and holds the reused PID until the observer finishes.
# Closing the parent's gate releases an unreaped child, including on parent exit.
{% unless flag?(:darwin) %}
  {% raise "The PID reuse fixture requires Darwin." %}
{% end %}

require "../../native/helper/protocol"
require "../../native/helper/darwin"

module ProcessControl::Internal::Unix::Owner
  def self.emit(verb : UInt8*, value : UInt64) : Bool
    report(1, verb, "".to_unsafe, value) == 0
  end

  def self.byte(fd : Int32, value : UInt8) : Bool
    loop do
      count = System.write(fd, pointerof(value), 1_u64)
      return true if count == 1
      return false unless count == -4
    end
  end

  def self.receive(fd : Int32) : Int32
    value = 0_u8
    loop do
      count = System.read(fd, pointerof(value), 1_u64)
      return value.to_i32 if count == 1
      return -1 unless count == -4
    end
  end

  def self.collect(pid : Int32, status : Int32*) : Bool
    loop do
      result = System.waitpid(pid, status, 0)
      return true if result == pid
      return false unless result == -4
    end
  end

  def self.open_gate(gate : Int32*) : Bool
    descriptors = uninitialized Int32[2]
    return false if System.pipe(descriptors.to_unsafe) < 0
    gate[0] = descriptors.to_unsafe[0]
    gate[1] = descriptors.to_unsafe[1]
    true
  end

  def self.exercise(current : Int32*, gate : Int32*, gate_ready : Bool*) : Int32
    return 70 unless open_gate(gate)
    gate_ready.value = true
    original = System.fork
    return 71 if original < 0
    if original == 0
      System.close(gate[1])
      receive(gate[0])
      System.exit(23)
    end
    current.value = original
    return 72 unless emit("ORIGINAL ".to_unsafe, original.to_u64!)
    if receive(0) < 0
      System.close(gate[1])
      System.close(gate[0])
      gate_ready.value = false
      status = 0
      return 89 unless collect(original, pointerof(status))
      current.value = 0
      emit("ABORTED ".to_unsafe, status.to_u64!)
      return 73
    end
    System.close(gate[1])
    System.close(gate[0])
    gate_ready.value = false
    status = 0
    return 74 unless collect(original, pointerof(status))
    current.value = 0
    return 75 unless emit("REAPED ".to_unsafe, status.to_u64!)
    return 76 unless open_gate(gate)
    gate_ready.value = true
    count = 0
    while count < 250_000
      candidate = System.fork
      return 77 if candidate < 0
      if candidate == 0
        System.close(gate[1])
        value = receive(gate[0])
        if value == 72
          while receive(gate[0]) == 112
            System.exit(87) unless emit("ALIVE ".to_unsafe, 37_u64)
          end
        end
        System.exit(37)
      end
      current.value = candidate
      count &+= 1
      if candidate == original
        return 78 unless byte(gate[1], 72_u8)
        return 79 unless emit("REUSED ".to_unsafe, candidate.to_u64!) && emit("BIRTHS ".to_unsafe, count.to_u64!)
        command = receive(0)
        while command == 112
          return 88 unless byte(gate[1], 112_u8)
          command = receive(0)
        end
        System.kill(candidate, 9) if command < 0
        System.close(gate[1])
        System.close(gate[0])
        gate_ready.value = false
        status = 0
        return 80 unless collect(candidate, pointerof(status))
        current.value = 0
        return 81 unless emit("COLLECTED ".to_unsafe, status.to_u64!)
        return 0
      end
      return 82 unless byte(gate[1], 88_u8)
      return 83 unless collect(candidate, pointerof(status))
      current.value = 0
      if count.unsafe_mod(2000) == 0
        return 84 unless emit("PROGRESS ".to_unsafe, count.to_u64!)
        return 85 if System.poll(0, 0) > 0
      end
    end
    System.close(gate[1])
    System.close(gate[0])
    gate_ready.value = false
    emit("EXHAUSTED ".to_unsafe, count.to_u64!)
    86
  end

  def self.run : Int32
    return 90 if ignore_pipe < 0
    gate = uninitialized Int32[2]
    current = 0
    gate_ready = false
    result = exercise(pointerof(current), gate.to_unsafe, pointerof(gate_ready))
    if gate_ready
      System.close(gate.to_unsafe[1])
      System.close(gate.to_unsafe[0])
    end
    if current > 0
      System.kill(current, 9)
      status = 0
      collect(current, pointerof(status))
    end
    result
  end
end

fun main(argc : Int32, argv : UInt8**) : Int32
  ProcessControl::Internal::Unix::Owner::System.exit(ProcessControl::Internal::Unix::Owner.run)
end
