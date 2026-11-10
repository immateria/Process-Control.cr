module ProcessControl::Internal::Unix::Owner
  def self.cloexec(fd : Int32) : Int32
    flags = LibC.fcntl(fd, LibC::F_GETFD)
    return -1 if flags < 0
    LibC.fcntl(fd, LibC::F_SETFD, flags | LibC::FD_CLOEXEC)
  end

  def self.close_foreign : Int32
    path = {{ flag?(:darwin) ? "/dev/fd" : "/proc/self/fd" }}
    directory = LibC.opendir(path.to_unsafe)
    return -1 if directory.null?
    keep = LibC.dirfd(directory)
    Errno.value = Errno.new(0)
    loop do
      entry = LibC.readdir(directory)
      break if entry.null?
      cursor = entry.as(UInt8*) + offsetof(LibC::Dirent, @d_name)
      value = uninitialized UInt64
      if number(pointerof(cursor), pointerof(value)) && cursor.value == 0 && value > 2 && value <= 2147483647_u64
        fd = value.to_i32!
        LibC.close(fd) unless fd == keep
      end
      Errno.value = Errno.new(0)
    end
    error = Errno.value
    LibC.closedir(directory)
    Errno.value = error
    error.value == 0 ? 0 : -1
  end
end
