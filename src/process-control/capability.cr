module ProcessControl::Capability
  struct Operation
    getter name : String

    def initialize(@name)
      raise ArgumentError.new("empty operation identifier") if @name.empty?
    end
  end

  enum Binding
    Sampled
    Retained
    Delegated
    Checked
  end

  class Request
    getter binding : Binding?
    @operations : Array(Operation)

    def initialize(operations : Enumerable(Operation), @binding = nil)
      @operations = operations.to_a.dup
      raise ArgumentError.new("duplicate operation identifier") unless @operations.uniq.size == @operations.size
    end

    def operations : Array(Operation)
      @operations.dup
    end

    def self.observation : self
      new([Operation.new("handle.observe")])
    end

    def self.wait : self
      new([Operation.new("handle.observe"), Operation.new("wait.exit")])
    end

    def self.control : self
      new([Operation.new("handle.observe"), Operation.new("control.stop"), Operation.new("control.kill")])
    end

    def self.child : self
      new([Operation.new("handle.observe"), Operation.new("wait.exit")])
    end
  end

  class Snapshot
    getter binding : Binding
    getter mechanism : String
    @operations : Array(Operation)

    def initialize(operations : Enumerable(Operation), @binding, @mechanism)
      @operations = operations.to_a.dup
      raise ArgumentError.new("duplicate operation identifier") unless @operations.uniq.size == @operations.size
    end

    def operations : Array(Operation)
      @operations.dup
    end

    def supports?(request : Request) : Bool
      (!request.binding || request.binding == @binding) && request.operations.all? { |operation| @operations.includes?(operation) }
    end
  end
end
