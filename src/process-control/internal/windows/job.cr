require "random/secure"

{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
  require "c/jobapi2"
{% end %}

module ProcessControl::Internal::Windows
  lib ABI
    struct Accounting
      total_user_time : Int64
      total_kernel_time : Int64
      period_user_time : Int64
      period_kernel_time : Int64
      page_faults : UInt32
      total_processes : UInt32
      active_processes : UInt32
      terminated_processes : UInt32
    end

    fun QueryInformationJobObject(job : LibC::HANDLE, info_class : UInt32, info : Void*, length : UInt32, return_length : UInt32*) : LibC::BOOL
    fun TerminateJobObject(job : LibC::HANDLE, exit_code : UInt32) : LibC::BOOL

    {% unless LibC.has_constant?("JOBOBJECT_EXTENDED_LIMIT_INFORMATION") %}
      struct Limits
        per_process_user_time : Int64
        per_job_user_time : Int64
        limit_flags : UInt32
        minimum_working_set_size : LibC::SizeT
        maximum_working_set_size : LibC::SizeT
        active_process_limit : UInt32
        affinity : LibC::SizeT
        priority_class : UInt32
        scheduling_class : UInt32
      end

      struct Extended
        basic : Limits
        io_counters : UInt64[6]
        process_memory_limit : LibC::SizeT
        job_memory_limit : LibC::SizeT
        peak_process_memory_used : LibC::SizeT
        peak_job_memory_used : LibC::SizeT
      end

      fun CreateJobObjectW(attributes : LibC::SECURITY_ATTRIBUTES*, name : UInt16*) : LibC::HANDLE
      fun SetInformationJobObject(job : LibC::HANDLE, info_class : UInt32, info : Void*, length : UInt32) : LibC::BOOL
    {% end %}
  end

  class Job < Containment::Controller
    MECHANISM     = "windows-job"
    private KILL_ON_CLOSE = 0x0000_2000_u32
    private ACCOUNTING    =           1_u32

    getter identity : Containment::Identity
    getter capabilities : Capability::Snapshot

    @mutex = Mutex.new
    @launcher : Platform::Windows::Launcher? = nil
    @release : Control::Release::Result? = nil

    def initialize(@native : LibC::HANDLE, @identity, @capabilities)
    end

    def self.create(request : Containment::Request) : Containment::Creation::Result
      operations = %w(group.observe group.wait_empty group.spawn control.kill)
      capabilities = Capability::Snapshot.new(operations.map { |name| Capability::Operation.new(name) }, :retained, MECHANISM)
      unless capabilities.supports?(request.required)
        return Containment::Creation::Rejected.new(Error::Unsupported.new("Windows Job cannot satisfy requested containment"))
      end

      identity = Containment::Identity.new(MECHANISM, Random::Secure.hex(16))
      native = {% if LibC.has_constant?("JOBOBJECT_EXTENDED_LIMIT_INFORMATION") %}
                 LibC.CreateJobObjectW(nil, nil)
               {% else %}
                 ABI.CreateJobObjectW(nil, nil)
               {% end %}
      return Containment::Creation::Rejected.new(Windows.error("CreateJobObjectW")) if native.null?

      result = {% if LibC.has_constant?("JOBOBJECT_EXTENDED_LIMIT_INFORMATION") %}
                 limits = LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
                 limits.basicLimitInformation.limitFlags = KILL_ON_CLOSE
                 LibC.SetInformationJobObject(native, LibC::JOBOBJECTINFOCLASS::ExtendedLimitInformation, pointerof(limits), sizeof(LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32)
               {% else %}
                 limits = ABI::Extended.new
                 limits.basic.limit_flags = KILL_ON_CLOSE
                 ABI.SetInformationJobObject(native, 9_u32, pointerof(limits), sizeof(ABI::Extended).to_u32)
               {% end %}
      error = Windows.error("SetInformationJobObject(KILL_ON_JOB_CLOSE)") if result == 0
      controller = new(native, identity, capabilities)
      group = ProcessControl::Group.new(controller, request)
      unless error
        begin
          Attributes.check_job(native)
        rescue ex : ProcessControl::Error
          error = ex
        end
      end
      if error
        cleanup = group.close
        error = Platform::Windows::Job::Creation::Failed.new(error, group) unless cleanup.complete?
        return Containment::Creation::Rejected.new(error)
      end
      Containment::Creation::Created.new(group)
    end

    def launcher : Spawn::Launcher?
      @mutex.synchronize { @launcher ||= Platform::Windows::Launcher.new(self) }
    end

    def with_handle(& : LibC::HANDLE -> T) : T forall T
      @mutex.synchronize do
        raise Error::Closed.new("Windows Job handle is closed") if @release
        yield @native
      end
    end

    def observe : Containment::Observation
      with_handle do |handle|
        info = ABI::Accounting.new
        if ABI.QueryInformationJobObject(handle, ACCOUNTING, pointerof(info), sizeof(ABI::Accounting).to_u32, nil) == 0
          raise Windows.error("QueryInformationJobObject")
        end
        Containment::Observation.new(@identity, info.active_processes == 0 ? Containment::Population::Empty : Containment::Population::Populated)
      end
    end

    def control(request : Control::Request, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Group::Result
      unless request.is_a?(Control::Kill::Request)
        return Control::Group::Result.new(request, ([] of Control::Result), MECHANISM, Error::Unsupported.new("Windows Job does not support requested control"))
      end
      effect = with_handle do |handle|
        if ABI.TerminateJobObject(handle, request.exit_code || 1_u32) == 0
          Control::Report::Failure.new(Windows.diagnostic("TerminateJobObject"))
        else
          Control::Report::Success.new("TerminateJobObject accepted the request")
        end
      end
      Control::Group::Result.new(request, ([] of Control::Result), MECHANISM, effect: effect)
    end

    def attach(handle : Handle::Borrowed, *, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Containment::Membership::Result
      request = Containment::Membership::Request.new
      refusal = Control::Refused.new(Error::Unsupported.new("Windows Job supports launch-time assignment"))
      control = Control::Result.new(request, handle.identity, refusal, MECHANISM)
      Containment::Membership::Result.new(handle.identity, @identity, control)
    end

    def release(*, deadline : Wait::Deadline, cancel : Wait::Cancellation?) : Control::Release::Result
      @mutex.synchronize do
        if previous = @release
          return previous
        end
        result = Windows.release(@native, "Windows Job handle", deadline, cancel)
        @release = result unless result.state.retryable?
        result
      end
    end
  end
end
