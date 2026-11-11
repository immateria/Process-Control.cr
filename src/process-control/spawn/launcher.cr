module ProcessControl::Spawn
  abstract class Extension
    abstract def name : String
  end

  class Plan
    getter executable : String
    getter directory : String
    getter stdio : Stream::Stdio
    getter required : Capability::Request
    getter group : ProcessControl::Group?

    def initialize(@executable, args : Array(String), environment : Hash(String, String), @directory, @stdio, @required, extensions : Array(Extension), @group = nil)
      @args = args.dup
      @environment = environment.dup
      @extensions = extensions.dup
    end

    def args : Array(String)
      @args.dup
    end

    def environment : Hash(String, String)
      @environment.dup
    end

    def extensions : Array(Extension)
      @extensions.dup
    end
  end

  module Attempt
    struct Registered
      getter registration : Registration

      def initialize(@registration)
      end
    end

    struct Rejected
      getter result : Spawn::Rejected

      def initialize(error : ProcessControl::Error, cleanup = Control::Release::Result.complete, attempted = false)
        @result = Spawn::Rejected.new(error, cleanup, attempted)
      end
    end

    struct Pending
      getter owner : Spawn::Pending

      getter? wait : Bool

      def initialize(@owner, *, @wait = true)
      end
    end

    alias Result = Registered | Rejected | Pending
  end

  abstract class Launcher
    abstract def launch(plan : Plan, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Attempt::Result

    def self.default : Launcher?
      {% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
        Platform::Unix::Launcher.default
      {% elsif flag?(:windows) %}
        Platform::Windows::Launcher.new
      {% else %}
        nil
      {% end %}
    end
  end
end
