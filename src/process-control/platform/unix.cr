require "socket"
require "random/secure"
require "c/fcntl"
require "./unix/helper"
require "../internal/unix/session"
require "../internal/unix/work"
require "../internal/unix/observer"

module ProcessControl::Platform::Unix
  class Launcher < Spawn::Launcher
    @@mutex = Mutex.new
    @@default : Launcher? = nil
    @mutex = Mutex.new
    @starting = 0

    getter helper : String
    getter startup_timeout : Time::Span

    def initialize(@helper = Helper.path, @startup_timeout = 10.seconds, @capacity = 16)
      raise ArgumentError.new("invalid launch capacity") if @capacity <= 0
      raise ArgumentError.new("startup timeout must be positive") unless @startup_timeout > Time::Span.zero
    end

    def self.default : Launcher
      @@mutex.synchronize { @@default ||= new }
    end

    def self.capabilities : Capability::Snapshot
      operations = %w(handle.observe wait.exit control.stop control.kill control.signal control.suspend control.resume)
      Capability::Snapshot.new(operations.map { |name| Capability::Operation.new(name) }, :delegated, "unix-helper-v1")
    end

    def launch(plan : Spawn::Plan, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Spawn::Attempt::Result
      unless Internal.executable?(@helper)
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("build the Unix helper with crystal run scripts/build-helper.cr"))
      end
      unless plan.group.nil? && plan.extensions.empty? && self.class.capabilities.supports?(plan.required)
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("requested launch extension or authority profile is unavailable"))
      end
      acquired = @mutex.synchronize do
        if @starting < @capacity
          @starting += 1
          true
        else
          false
        end
      end
      return Spawn::Attempt::Rejected.new(Error::Unsupported.new("native launch capacity exhausted")) unless acquired
      work = Internal::Unix::Work.new(self, plan)
      work.pending.on_settle { @mutex.synchronize { @starting -= 1 }; nil }
      work.start
      Spawn::Attempt::Pending.new(work.pending)
    end
  end
end
