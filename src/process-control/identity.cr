module ProcessControl
  struct Identity
    struct Scope
      getter origin : String
      getter host : String?
      getter boot : String?
      getter namespace : String?

      def initialize(@origin, *, @host = nil, @boot = nil, @namespace = nil)
      end

      def self.local : self
        new("local")
      end
    end

    struct Generation
      getter domain : String
      getter value : String

      def initialize(@domain, @value)
      end
    end

    enum Comparison
      Different
      Consistent
      Indeterminate
    end

    class Mismatch < ProcessControl::Error; end

    class Unverifiable < ProcessControl::Error; end

    getter pid : Int64
    getter scope : Scope
    getter generation : Generation?

    def initialize(pid : Int, @scope = Scope.local, @generation = nil)
      raise ArgumentError.new("process identifier must be positive") unless pid > 0
      raise ArgumentError.new("process identifier exceeds immutable model range") unless pid <= Int64::MAX
      @pid = pid.to_i64
    end

    def same_pid?(other : Identity) : Bool
      @pid == other.pid && @scope == other.scope
    end

    def compare(other : Identity) : Comparison
      return Comparison::Different if @pid != other.pid || @scope.origin != other.scope.origin
      own = {@scope.host, @scope.boot, @scope.namespace}
      theirs = {other.scope.host, other.scope.boot, other.scope.namespace}
      own.zip(theirs).each do |left, right|
        return Comparison::Different if left && right && left != right
      end
      return Comparison::Indeterminate unless @scope == other.scope
      if left = @generation
        return Comparison::Indeterminate unless right = other.generation
        return Comparison::Indeterminate unless left.domain == right.domain
        return left.value == right.value ? Comparison::Consistent : Comparison::Different
      end
      other.generation ? Comparison::Indeterminate : Comparison::Consistent
    end
  end
end
