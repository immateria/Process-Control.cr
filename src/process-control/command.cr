module ProcessControl
  class Command
    getter executable : String
    getter cwd : String?
    getter environment : Spawn::Environment
    getter stdio : Stream::Stdio
    @args : Array(String)
    @extensions : Array(Spawn::Extension)

    def initialize(@executable : String, args : Enumerable(String) = [] of String,
                   @environment = Spawn::Environment.new, @cwd = nil, @stdio = Stream::Stdio.new,
                   extensions : Enumerable(Spawn::Extension) = [] of Spawn::Extension)
      raise ArgumentError.new("empty or NUL-containing executable") if @executable.empty? || @executable.includes?('\0')
      @args = args.to_a.dup
      raise ArgumentError.new("NUL-containing argument") if @args.any?(&.includes?('\0'))
      raise ArgumentError.new("NUL-containing working directory") if @cwd.try(&.includes?('\0'))
      @extensions = extensions.to_a.dup
      names = @extensions.map { |extension| extension.name.as(String) }
      raise ArgumentError.new("duplicate extension") unless names.uniq.size == @extensions.size
    end

    def args : Array(String)
      @args.dup
    end

    def with_env(edits, *, inherit : Bool = true) : Command
      Command.new(@executable, @args, Spawn::Environment.new(edits, inherit), @cwd, @stdio, @extensions)
    end

    def with_cwd(cwd : String) : Command
      Command.new(@executable, @args, @environment, cwd, @stdio, @extensions)
    end

    def with_stdio(stdio : Stream::Stdio) : Command
      Command.new(@executable, @args, @environment, @cwd, stdio, @extensions)
    end

    def with(extension : Spawn::Extension) : Command
      Command.new(@executable, @args, @environment, @cwd, @stdio, @extensions + [extension])
    end

    def prepare(*, required : Capability::Request = Capability::Request.child, group : Group? = nil) : Spawn::Plan
      caller_directory = Dir.current
      environment = @environment.resolve
      directory = @cwd ? File.expand_path(@cwd.not_nil!, caller_directory) : caller_directory
      path = if @executable.includes?(File::SEPARATOR) || @executable.includes?('/')
               File.expand_path(@executable, caller_directory)
             else
               search = environment["PATH"]? || ENV["PATH"]? || ""
               search.split(Process::PATH_DELIMITER).map { |entry| File.expand_path(File.join(entry, @executable), caller_directory) }
                 .find { |candidate| Internal.executable?(candidate) }
             end
      raise Error::Missing.new("executable not found: #{@executable}") unless path
      Spawn::Plan.new(path, @args, environment, directory, @stdio, required, @extensions, group)
    end

    def spawn(*, launcher : Spawn::Launcher? = nil, group : Group? = nil, required : Capability::Request = Capability::Request.child,
              deadline : Wait::Deadline = Wait::Deadline.none, cancel : Wait::Cancellation? = nil) : Spawn::Result
      if cancel.try(&.cancelled?) || (deadline.expired? && !deadline.immediate?)
        return Spawn::Rejected.new(Error.new("spawn cancelled or expired before creation"))
      end
      provider = launcher || Spawn::Launcher.default
      return Spawn::Rejected.new(Error::Unsupported.new("no qualified native launcher selected")) unless provider
      plan = begin
        prepare(required: required, group: group)
      rescue ex : Error
        return Spawn::Rejected.new(ex)
      end
      if group
        group.admit_spawn { execute(provider, plan, deadline: deadline, cancel: cancel) }
      else
        execute(provider, plan, deadline: deadline, cancel: cancel)
      end
    end

    private def execute(provider : Spawn::Launcher, plan : Spawn::Plan, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Spawn::Result
      case attempt = provider.launch(plan, deadline: deadline, cancel: cancel)
      in Spawn::Attempt::Registered
        attempt.registration.publish(required: plan.required)
      in Spawn::Attempt::Rejected
        attempt.result
      in Spawn::Attempt::Pending
        attempt.owner.resolve(deadline: deadline, cancel: cancel)
      end
    end
  end
end
