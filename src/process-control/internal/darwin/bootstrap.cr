require "./context"

module ProcessControl::Internal::Darwin
  # The managed parent creates only the audited, unmanaged helper. The target
  # remains the helper's child and its status never comes from this owner.
  class Bootstrap
    alias Kernel = ::Native::Kernel::Darwin

    getter pid : Int64 = 0_i64
    @started = false
    @runtime_channel : Channel(Int32)? = nil
    @input : IO::FileDescriptor? = nil
    @output : IO::FileDescriptor? = nil
    @error : IO::FileDescriptor? = nil
    @raw = [] of Int32
    @actions = [] of Bytes
    @cleanup_failure : Diagnostic? = nil

    # Configuration only: Work must retain this owner before calling start.
    def initialize(@helper : String, @arguments : Array(String), @env : Hash(String, String), @chdir : String,
                   input : ::Process::Stdio, output : ::Process::Stdio, error : ::Process::Stdio)
      @stdio = {input, output, error}
    end

    def self.preflight!(major : Int32 = Context.major) : Kernel::Spawn::Profile
      # Dependency layout availability does not qualify a consumer release.
      unless major == 24 || major == 25
        raise Error::Unsupported.new("direct helper bootstrap requires an audited Darwin 24 or 25 spawn ABI")
      end
      Kernel::Spawn.profile(major) ||
        raise Error::Unsupported.new("direct helper bootstrap requires an audited Darwin 24 or 25 spawn ABI")
    end

    def start : Nil
      raise Error::Ownership.new("helper bootstrap was already started") if @started
      @started = true
      # Native-Kernel supplies the audited fixed-copy layout. This consumer
      # owns release admission and the restricted zero-filled helper profile.
      profile = self.class.preflight!
      argv = [@helper] + @arguments
      environment = @env.map { |key, value| "#{key}=#{value}" }
      (argv + environment + [@chdir]).each do |text|
        raise ArgumentError.new("bootstrap argument contains NUL") if text.includes?('\0')
      end
      argv_pointers = argv.map(&.to_unsafe) + [Pointer(UInt8).null]
      env_pointers = environment.map(&.to_unsafe) + [Pointer(UInt8).null]
      @stdio.each_with_index { |spec, index| prepare_stdio(spec, index, profile) }
      add_path_action(profile, 5, 0, @chdir)
      actions = Bytes.new(profile.actions_header_size + @actions.size * profile.action_size, 0_u8)
      (actions.to_unsafe + profile.actions_capacity_offset).as(Int32*).value = @actions.size
      (actions.to_unsafe + profile.actions_count_offset).as(Int32*).value = @actions.size
      @actions.each_with_index do |action, index|
        actions[profile.actions_header_size + index * profile.action_size, profile.action_size].copy_from(action)
      end
      attributes = Bytes.new(profile.attributes_size, 0_u8)
      # SETSIGDEF | SETSIGMASK | CLOEXEC_DEFAULT. The trusted helper gates target
      # creation on authenticated START; it must be able to exit on startup EOF.
      (attributes.to_unsafe + profile.flags_offset).as(UInt16*).value = 0x400c_u16
      (attributes.to_unsafe + profile.defaults_offset).as(UInt32*).value = 0xfffefeff_u32 # all except SIGKILL/SIGSTOP
      (attributes.to_unsafe + profile.mask_offset).as(UInt32*).value = 0_u32
      descriptor = Bytes.new(profile.descriptor_size, 0_u8)
      (descriptor.to_unsafe + profile.descriptor_attribute_size_offset).as(UInt64*).value = attributes.size.to_u64
      (descriptor.to_unsafe + profile.descriptor_attributes_offset).as(UInt64*).value = attributes.to_unsafe.address
      (descriptor.to_unsafe + profile.descriptor_actions_size_offset).as(UInt64*).value = actions.size.to_u64
      (descriptor.to_unsafe + profile.descriptor_actions_offset).as(UInt64*).value = actions.to_unsafe.address
      child = 0
      result = Kernel::Spawn.create(pointerof(child), @helper.to_unsafe, descriptor.to_unsafe.as(Void*),
        argv_pointers.to_unsafe, env_pointers.to_unsafe)
      raise native_error("create", result.error) unless result.error == 0 && child > 0
      @pid = child.to_i64
      # Register only for runtime bookkeeping. This PID-keyed status is never
      # used as helper identity, target status, or evidence of target exit.
      @runtime_channel = Crystal::System::SignalChildHandler.wait(child)
      release_raw
      raise Control::Cleanup::Failed.new("helper descriptor cleanup is uncertain", @cleanup_failure) if @cleanup_failure
    end

    def input : IO::FileDescriptor
      @input || raise Error::Ownership.new("helper stdin is not piped")
    end

    def output : IO::FileDescriptor
      @output || raise Error::Ownership.new("helper stdout is not piped")
    end

    def error : IO::FileDescriptor
      @error || raise Error::Ownership.new("helper stderr is not piped")
    end

    def close : Nil
      {@input, @output, @error}.each do |io|
        next unless io && !io.closed?
        begin
          io.close
        rescue ex
          @cleanup_failure ||= Diagnostic.new("helper.stdio", ex.message || ex.class.name, stage: "cleanup")
        end
      end
      release_raw
      raise Control::Cleanup::Failed.new("helper resource cleanup is uncertain", @cleanup_failure) if @cleanup_failure
    end

    def wait : Nil
      return if @pid == 0
      # This may consume a stale PID-keyed runtime entry. Work has already
      # closed these wrappers after duplicating streams, or on startup failure;
      # this bookkeeping cannot close transferred endpoints or settle a target.
      @runtime_channel.try(&.receive?)
      close
    end

    private def prepare_stdio(spec : ::Process::Stdio, target : Int32, profile : Kernel::Spawn::Profile) : Nil
      case spec
      when ::Process::Redirect
        case spec
        in .pipe?
          pipe = Kernel::Descriptor.pipe
          raise native_error("pipe", pipe.error) unless pipe.error == 0
          first = pipe.primary.to_i32!
          second = pipe.secondary.to_i32!
          @raw << first << second
          first = preserve_stdio(first)
          second = preserve_stdio(second)
          {first, second}.each do |fd|
            result = Kernel::Descriptor.fcntl(fd, 2, 1)
            raise native_error("cloexec", result.error) unless result.error == 0
          end
          parent_fd, child_fd = target == 0 ? {second, first} : {first, second}
          flags = Kernel::Descriptor.fcntl(parent_fd, 3)
          raise native_error("flags", flags.error) unless flags.error == 0
          nonblocking = Kernel::Descriptor.fcntl(parent_fd, 4, flags.primary.to_i32! | 4)
          raise native_error("nonblocking", nonblocking.error) unless nonblocking.error == 0
          io = IO::FileDescriptor.new(parent_fd)
          @raw.delete(parent_fd)
          case target
          when 0 then @input = io
          when 1 then @output = io
          when 2 then @error = io
          end
          add_fd_action(profile, 2, child_fd, target)
        in .close?
          add_path_action(profile, 0, target, "/dev/null", target == 0 ? 0 : 1)
        in .inherit?
          result = Kernel::Descriptor.fcntl(target, 1)
          if result.error == 0
            add_fd_action(profile, 3, target)
          elsif result.error != 9
            raise native_error("inherit", result.error)
          end
        end
      when IO::FileDescriptor
        # Pin the supplied descriptor before arranging any stdio action. This
        # also avoids action-order cycles when a supplied fd is itself 0..2.
        duplicate = Kernel::Descriptor.fcntl(spec.fd, 67, 3)
        raise native_error("duplicate", duplicate.error) unless duplicate.error == 0
        fd = duplicate.primary.to_i32!
        @raw << fd
        add_fd_action(profile, 2, fd, target)
      else
        raise Error::Unsupported.new("helper bootstrap requires native descriptor stdio")
      end
    end

    private def preserve_stdio(fd : Int32) : Int32
      return fd if fd >= 3
      duplicate = Kernel::Descriptor.fcntl(fd, 67, 3)
      raise native_error("duplicate", duplicate.error) unless duplicate.error == 0
      pinned = duplicate.primary.to_i32!
      @raw << pinned
      @raw.delete(fd)
      closed = Kernel::Descriptor.close(fd)
      unless closed.error == 0
        @cleanup_failure ||= Diagnostic.new("helper.close", "temporary stdio descriptor close failed",
          native_domain: "errno", native_code: closed.error.to_i64, stage: "cleanup")
        raise Control::Cleanup::Failed.new(@cleanup_failure.not_nil!.message, @cleanup_failure)
      end
      pinned
    end

    private def add_fd_action(profile : Kernel::Spawn::Profile, kind : Int32, fd : Int32, destination : Int32 = 0) : Nil
      action = Bytes.new(profile.action_size, 0_u8)
      (action.to_unsafe + profile.action_type_offset).as(Int32*).value = kind
      (action.to_unsafe + profile.action_fd_offset).as(Int32*).value = fd
      (action.to_unsafe + profile.action_destination_offset).as(Int32*).value = destination
      @actions << action
    end

    private def add_path_action(profile : Kernel::Spawn::Profile, kind : Int32, fd : Int32, path : String, flags : Int32 = 0) : Nil
      if path.bytesize >= profile.path_capacity
        raise ArgumentError.new("helper action pathname exceeds #{profile.path_capacity - 1} bytes")
      end
      action = Bytes.new(profile.action_size, 0_u8)
      (action.to_unsafe + profile.action_type_offset).as(Int32*).value = kind
      (action.to_unsafe + profile.action_fd_offset).as(Int32*).value = fd
      offset = if kind == 0
                 (action.to_unsafe + profile.open_flags_offset).as(Int32*).value = flags
                 (action.to_unsafe + profile.open_mode_offset).as(UInt16*).value = 0_u16
                 profile.open_path_offset
               else
                 profile.chdir_path_offset
               end
      action[offset, path.bytesize].copy_from(path.to_slice)
      @actions << action
    end

    private def release_raw : Nil
      # Relinquish each numeric fd before close. A failed close is uncertain
      # and must not later close a different object after descriptor reuse.
      descriptors = @raw
      @raw = [] of Int32
      descriptors.each do |fd|
        result = Kernel::Descriptor.close(fd)
        unless result.error == 0
          @cleanup_failure ||= Diagnostic.new("helper.close", "raw descriptor close failed",
            native_domain: "errno", native_code: result.error.to_i64, stage: "cleanup")
        end
      end
    end

    private def native_error(operation : String, error : Int32) : ProcessControl::Error
      detail = Diagnostic.new("helper.#{operation}", "direct helper #{operation} failed",
        native_domain: "errno", native_code: error.to_i64, stage: "bootstrap")
      Error.new(detail.message, detail)
    end
  end
end
