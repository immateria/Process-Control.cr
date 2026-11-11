require "socket"
require "random/secure"
require "c/fcntl"
require "./unix/helper"
require "../internal/unix/session"
{% if flag?(:darwin) %}
  require "../internal/darwin/bootstrap"
{% end %}
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
      {% if flag?(:darwin) %}
        begin
          Internal::Darwin::Bootstrap.preflight!
        rescue ex : Error::Unsupported
          return Spawn::Attempt::Rejected.new(ex)
        end
      {% end %}
      unless Internal.executable?(@helper)
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("build the Unix helper with crystal run scripts/build-helper.cr"))
      end
      unless self.class.capabilities.supports?(plan.required)
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("requested Unix launch authority profile is unavailable"))
      end
      setup = [] of String
      plan.extensions.each do |extension|
        case extension
        when Spawn::Session
          setup << "--session"
        when Resource::Limit
          setup.concat(["--limit", extension.kind.to_s.downcase, extension.soft.to_s, extension.hard.to_s])
        else
          return Spawn::Attempt::Rejected.new(Error::Unsupported.new("Unix launch extension is unavailable: #{extension.name}"))
        end
      end
      if group = plan.group
        {% if flag?(:linux) %}
          unless group.claim_launch(plan, self)
            return Spawn::Attempt::Rejected.new(Error::Ownership.new("cgroup launch plan is not admitted by its group"))
          end
          begin
            birth = group.birth
            unless birth
              return Spawn::Attempt::Rejected.new(Error::Unsupported.new("group has no available cgroup birth placement"))
            end
            setup.concat(["--cgroup", birth.path, birth.device.to_s, birth.inode.to_s])
          rescue ex : ProcessControl::Error
            return Spawn::Attempt::Rejected.new(ex)
          end
        {% else %}
          return Spawn::Attempt::Rejected.new(Error::Unsupported.new("native group launch is unavailable on this platform"))
        {% end %}
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
      work = Internal::Unix::Work.new(self, plan, setup)
      work.pending.on_settle { @mutex.synchronize { @starting -= 1 }; nil }
      work.start
      Spawn::Attempt::Pending.new(work.pending)
    end
  end
end
