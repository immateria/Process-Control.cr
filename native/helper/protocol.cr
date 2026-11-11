require "./text"

module ProcessControl::Internal::Unix::Owner
  struct Frame
    @used = 0

    def initialize(@data : UInt8*, @capacity : Int32)
    end

    def text(value : UInt8*) : Bool
      return false if @capacity <= 0 || @used >= @capacity
      count = Text.size(value, @capacity &- @used)
      return false if count < 0
      return false if @used >= @capacity &- count
      offset = 0
      while offset < count
        @data[@used] = value[offset]
        @used &+= 1
        offset &+= 1
        asm("" ::: "memory" : "volatile")
      end
      @data[@used] = 0_u8
      true
    end

    def integer(value : UInt64) : Bool
      digits = uninitialized UInt8[20]
      count = 0
      loop do
        digits.to_unsafe[count] = (value.unsafe_mod(10_u64) &+ 48_u64).to_u8!
        count &+= 1
        value = value.unsafe_div(10_u64)
        break if value == 0
      end
      return false if count >= @capacity || @used >= @capacity &- count
      while count > 0
        count &-= 1
        @data[@used] = digits.to_unsafe[count]
        @used &+= 1
        asm("" ::: "memory" : "volatile")
      end
      @data[@used] = 0_u8
      true
    end

    def signed(value : Int64) : Bool
      if value < 0
        text("-".to_unsafe) && integer((0_i64 &- value).to_u64!)
      else
        integer(value.to_u64!)
      end
    end
  end

  # Decimal UInt64 with an explicit bound; no checked arithmetic or exceptions.
  def self.number(cursor : UInt8**, result : UInt64*) : Bool
    input = cursor.value
    return false unless input.value >= 48 && input.value <= 57
    value = 0_u64
    while input.value >= 48 && input.value <= 57
      digit = (input.value &- 48_u8).to_u64
      return false if value > 1844674407370955161_u64 || (value == 1844674407370955161_u64 && digit > 5)
      value = value &* 10_u64 &+ digit
      input += 1
    end
    cursor.value = input
    result.value = value
    true
  end

  def self.request(line : UInt8*, token : UInt8*, sequence : UInt64*, signal : Int32*) : Int32
    prefix = "SIGNAL ".to_unsafe
    cursor = line
    while prefix.value != 0
      return -1 if cursor.value != prefix.value
      cursor += 1
      prefix += 1
    end
    actual = cursor
    length = 0
    while cursor.value != 0 && cursor.value != 32
      length &+= 1
      return -1 if length > 64
      cursor += 1
    end
    return -1 if length == 0 || cursor.value != 32
    cursor.value = 0_u8
    matched = Text.equal(actual, token)
    cursor += 1
    return -1 unless number(pointerof(cursor), sequence) && cursor.value == 32
    cursor += 1
    value = uninitialized UInt64
    return -1 unless number(pointerof(cursor), pointerof(value)) && cursor.value == 0
    return -1 if value == 0 || value >= SIGNALS.to_u64!
    signal.value = value.to_i32!
    matched ? 1 : 0
  end

  def self.report(fd : Int32, verb : UInt8*, token : UInt8*, value : UInt64) : Int32
    bytes = uninitialized UInt8[192]
    frame = Frame.new(bytes.to_unsafe, 192)
    return -1 unless frame.text(verb) && frame.text(token) && frame.text(" ".to_unsafe) && frame.integer(value) && frame.text("\n".to_unsafe)
    send_line(fd, bytes.to_unsafe)
  end

  def self.report_exit(fd : Int32, token : UInt8*, status : Int32) : Int32
    bytes = uninitialized UInt8[192]
    frame = Frame.new(bytes.to_unsafe, 192)
    return -1 unless frame.text("EXIT ".to_unsafe) && frame.text(token) && frame.text(" ".to_unsafe) &&
                     frame.integer(status.to_u32!.to_u64) && frame.text(" NONE\n".to_unsafe)
    send_line(fd, bytes.to_unsafe)
  end
end
