module ProcessControl::Internal::Darwin
  struct Token
    getter words : StaticArray(UInt32, 8)

    def initialize(@words)
    end

    def pid : UInt32
      @words[5]
    end

    def version : UInt32
      @words[7]
    end

    def identity : ProcessControl::Identity
      generation = ProcessControl::Identity::Generation.new("darwin.audit.pidversion", version.to_s)
      ProcessControl::Identity.new(pid, generation: generation)
    end
  end
end
