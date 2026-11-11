module ProcessControl::Internal::Unix::Owner
  def self.cloexec(fd : Int32) : Int32
    flags = System.fcntl(fd, 1)
    return flags if flags < 0
    System.fcntl(fd, 2, flags | 1)
  end

  def self.close_foreign : Int32
    # Darwin O_DIRECTORY | O_CLOEXEC, preserving the descriptor used to scan.
    directory = System.open("/dev/fd".to_unsafe, 0x01100000)
    return directory if directory < 0
    bytes = uninitialized UInt8[4096]
    base = 0_i64
    result = scan_descriptors(directory, bytes.to_unsafe, pointerof(base))
    System.close(directory)
    result
  end

  private def self.scan_descriptors(directory : Int32, bytes : UInt8*, base : Int64*) : Int32
    loop do
      received = System.entries(directory, bytes, 4096, base)
      next if received == -4
      return received.to_i32! if received < 0
      return 0 if received == 0
      return -5 if received > 4096
      offset = 0
      while offset < received
        # Darwin dirent64 has reclen at16, namlen at18 and name at21.
        return -5 if received &- offset < 22
        entry = bytes + offset
        length = (entry + 16).as(UInt16*).value.to_i32
        name = (entry + 18).as(UInt16*).value.to_i32
        return -5 if length < 22 || length > received &- offset || name >= length &- 21
        cursor = entry + 21
        return -5 unless cursor[name] == 0
        value = 0_u64
        if number(pointerof(cursor), pointerof(value)) && cursor.value == 0 && value > 2 && value <= 2147483647_u64
          fd = value.to_i32!
          System.close(fd) unless fd == directory
        end
        offset &+= length
      end
    end
  end
end
