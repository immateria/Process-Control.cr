require "./kernel/process"

module ProcessControl::Internal::Darwin::Inspection
  # Process states from SDK sys/proc.h.
  private CREATING = 1_u32
  private RUNNABLE = 2_u32
  private SLEEPING = 3_u32
  private STOPPED  = 4_u32
  private ZOMBIE   = 5_u32

  def self.snapshot(limit : Int32) : ProcessControl::Inspection::Snapshot
    # Allow for PID zero and one additional positive PID to detect truncation.
    pids = Slice(Int32).new(limit + 2)
    result = Kernel::Process.list(pids.to_unsafe.as(Void*), pids.bytesize.to_i32)
    bytes = result.primary
    if result.error != 0 || bytes <= 0
      diagnostic = native_diagnostic("enumerate", result.error)
      raise Observation::Failed.new("could not enumerate Darwin processes", diagnostic)
    end
    unless bytes <= pids.bytesize && bytes % sizeof(Int32) == 0
      raise Observation::Failed.new("Darwin process roster has an unexpected native size")
    end

    observations = [] of ProcessControl::Observation
    seen = Set(Int32).new
    truncated = bytes == pids.bytesize
    (bytes // sizeof(Int32)).times do |index|
      pid = pids[index]
      next if pid == 0 || !seen.add?(pid)
      raise Observation::Failed.new("Darwin process roster has an invalid PID") if pid < 0
      if observations.size == limit
        truncated = true
        break
      end
      observations << sample(pid)
    end
    ProcessControl::Inspection::Snapshot.new(observations, truncated)
  end

  private def self.sample(pid : Int32) : ProcessControl::Observation
    info = LibProc::Record.new
    result = Kernel::Process.info(pid, LibProc::PIDT_BSDINFOWITHUNIQID, 1_u64, pointerof(info).as(Void*), sizeof(LibProc::Record))
    bytes = result.primary
    if result.error != 0 || bytes == 0
      diagnostic = native_diagnostic("sample", result.error)
      return Observation.new(Identity.new(pid), diagnostic: diagnostic)
    end
    unless bytes == sizeof(LibProc::Record) && info.bsd.pid == pid.to_u32
      diagnostic = Diagnostic.new("inspection.snapshot", "Darwin process record has an unexpected native identity or size", stage: "sample")
      return Observation.new(Identity.new(pid), diagnostic: diagnostic)
    end

    generation = Identity::Generation.new("darwin.audit.pidversion", info.unique.pid_version.to_u32!.to_s)
    identity = Identity.new(pid, generation: generation)
    case info.bsd.status
    when CREATING, SLEEPING
      Observation.new(identity, presence: :present, termination: :alive)
    when RUNNABLE
      Observation.new(identity, presence: :present, termination: :alive, execution: :runnable)
    when STOPPED
      Observation.new(identity, presence: :present, termination: :alive, execution: :stopped)
    when ZOMBIE
      Observation.new(identity, presence: :present, termination: :terminated, execution: :zombie)
    else
      diagnostic = Diagnostic.new("inspection.snapshot", "Darwin process record has an unknown state", stage: "sample")
      Observation.new(identity, presence: :present, diagnostic: diagnostic)
    end
  end

  private def self.native_diagnostic(stage : String, error : Int32) : Diagnostic
    Diagnostic.new("inspection.snapshot", "Darwin kernel process query failed", native_domain: "errno", native_code: error.to_i64, stage: stage)
  end

  def self.zombie?(pid : Int32) : Bool
    info = LibProc::Short.new
    # A nonzero argument asks XNU to include an unreaped zombie.
    result = Kernel::Process.info(pid, LibProc::PIDT_SHORTBSDINFO, 1_u64, pointerof(info).as(Void*), sizeof(LibProc::Short))
    result.error == 0 && result.primary == sizeof(LibProc::Short) && info.pid == pid.to_u32 && info.status == ZOMBIE
  end
end
