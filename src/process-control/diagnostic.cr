module ProcessControl
  struct Diagnostic
    getter operation : String
    getter message : String
    getter native_domain : String?
    getter native_code : Int64?
    getter stage : String?

    def initialize(@operation, @message, *, @native_domain = nil, @native_code = nil, @stage = nil)
    end
  end
end
