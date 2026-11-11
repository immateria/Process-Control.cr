require "../internal/windows/native"
require "../internal/windows/authority"
require "../internal/windows/abi"
require "../internal/windows/attributes"
require "../internal/windows/environment"
require "../internal/windows/executable"
require "../internal/windows/stdio"
require "../internal/windows/status"
require "../internal/windows/work"
require "../internal/windows/job"

module ProcessControl::Platform::Windows
  class Launcher < Spawn::Launcher
    def initialize(@job : Internal::Windows::Job? = nil)
    end

    def launch(plan : Spawn::Plan, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Spawn::Attempt::Result
      profile = Internal::Windows::Authority.profile(terminate: true)
      unless plan.extensions.empty? && profile.supports?(plan.required)
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("requested Windows launch extension or authority profile is unavailable"))
      end
      if @job
        group = plan.group
        unless group && group.launcher.same?(self) && group.claim_launch(plan, self)
          return Spawn::Attempt::Rejected.new(Error::Ownership.new("Windows Job launch lacks its group's admission"))
        end
      elsif plan.group
        return Spawn::Attempt::Rejected.new(Error::Unsupported.new("Windows launcher requires its bound Job group"))
      end
      Internal::Windows::Work.new(plan, profile, @job).launch(deadline: deadline, cancel: cancel)
    end
  end

  module Job
    module Creation
      class Failed < ProcessControl::Error
        getter failure : ProcessControl::Error
        getter owner : ProcessControl::Group

        def initialize(@failure, @owner)
          super("Windows Job creation refused with incomplete cleanup: #{@failure.message}", @failure.diagnostic)
        end
      end
    end

    def self.create(request : Containment::Request = Containment::Request.new) : Containment::Creation::Result
      Internal::Windows::Job.create(request)
    end
  end

  def self.open(pid : Int, *, required : Capability::Request = Capability::Request.observation, expected : ProcessControl::Identity? = nil) : Handle
    Internal::Windows::Authority.acquire(pid, required, expected)
  end
end

module ProcessControl
  def self.observe(pid : Int) : Observation
    handle = Platform::Windows.open(pid)
    begin
      observation = handle.observe
    ensure
      cleanup = handle.close
    end
    if cleanup && (failure = cleanup.records.find { |record| !record.state.complete? })
      return Observation.new(observation.identity, observation.presence, observation.termination,
        diagnostic: failure.diagnostic, exit_info: observation.exit_info)
    end
    observation
  rescue ex : Error::Missing
    Observation.new(Identity.new(pid), presence: :absent, diagnostic: ex.diagnostic)
  rescue ex : Error
    Observation.new(Identity.new(pid), diagnostic: ex.diagnostic)
  end
end
