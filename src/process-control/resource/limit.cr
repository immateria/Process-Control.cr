module ProcessControl::Resource
  # A finite POSIX resource limit applied to the target before exec.
  class Limit < Spawn::Extension
    enum Kind
      CPU         # CPU seconds
      File        # Bytes in one output file
      Core        # Core file bytes
      Descriptors # Open descriptor limit
    end

    getter kind : Kind
    getter soft : UInt64
    getter hard : UInt64

    def initialize(@kind, soft : Int, hard : Int = soft)
      unless @kind.in?(Kind::CPU, Kind::File, Kind::Core, Kind::Descriptors) && 0 <= soft <= hard < Int64::MAX
        raise ArgumentError.new("invalid finite POSIX resource limit")
      end
      @soft = soft.to_u64
      @hard = hard.to_u64
    end

    def name : String
      "resource.limit.#{@kind.to_s.downcase}"
    end
  end
end
