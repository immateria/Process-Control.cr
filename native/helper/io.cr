module ProcessControl::Internal::Unix::Owner
  def self.send_line(fd : Int32, line : UInt8*) : Int32
    length = Text.size(line, 192)
    return -1 if length < 0
    while length > 0
      sent = LibC.write(fd, line, length.to_u64!)
      next if sent < 0 && Errno.value == Errno::EINTR
      return -1 if sent <= 0
      line += sent
      length &-= sent.to_i32!
    end
    0
  end

  def self.read_line(fd : Int32, line : UInt8*, capacity : Int32) : Int32
    used = 0
    while used &+ 1 < capacity
      byte = uninitialized UInt8
      got = LibC.read(fd, pointerof(byte), 1)
      next if got < 0 && Errno.value == Errno::EINTR
      return -1 if got <= 0
      return -1 if byte == 0
      if byte == 10
        line[used] = 0_u8
        return 0
      end
      line[used] = byte
      used &+= 1
    end
    -1
  end
end
