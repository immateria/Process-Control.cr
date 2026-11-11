module ProcessControl::Internal::Unix::Owner
  def self.send_line(fd : Int32, line : UInt8*) : Int32
    length = Text.size(line, 4096)
    return -22 if length < 0
    remaining = length.to_u64!
    while remaining > 0
      sent = System.write(fd, line, remaining)
      next if sent == -4
      return sent.to_i32! if sent < 0
      return -5 if sent == 0
      line += sent
      remaining &-= sent.to_u64!
    end
    0
  end

  def self.read_line(fd : Int32, line : UInt8*, capacity : Int32) : Int32
    used = 0
    while used &+ 1 < capacity
      byte = 0_u8
      got = System.read(fd, pointerof(byte), 1_u64)
      next if got == -4
      return got.to_i32! if got < 0
      return -5 if got == 0 || byte == 0
      if byte == 10
        line[used] = 0_u8
        return 0
      end
      line[used] = byte
      used &+= 1
    end
    -22
  end
end
