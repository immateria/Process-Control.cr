require "./spec_helper"

describe PC::Inspection do
  it "rejects limits outside the bounded snapshot range" do
    expect_raises(ArgumentError) { PC::Inspection.snapshot(limit: 0) }
    expect_raises(ArgumentError) { PC::Inspection.snapshot(limit: Int32::MAX) }
  end

  it "retains a PID and native diagnostic for a skipped row" do
    diagnostic = PC::Diagnostic.new("inspection.snapshot", "process disappeared during sample",
      native_domain: "errno", native_code: 3_i64, stage: "sample")
    observation = PC::Observation.new(PC::Identity.new(123), diagnostic: diagnostic)
    rows = [observation]
    snapshot = PC::Inspection::Snapshot.new(rows, false)
    rows.clear
    snapshot.observations.should eq([observation])
    snapshot.skipped.should eq(1)
    snapshot.complete?.should be_false
  end

  {% if flag?(:darwin) %}
    it "includes a generation-bearing observation of the caller" do
      snapshot = PC::Inspection.snapshot
      observation = snapshot.observations.find! { |entry| entry.identity.pid == Process.pid }
      observation.presence.present?.should be_true
      observation.termination.alive?.should be_true
      observation.identity.generation.not_nil!.domain.should eq("darwin.audit.pidversion")

      snapshot.observations.clear
      snapshot.observations.should contain(observation)
      snapshot.skipped.should eq(snapshot.observations.count { |entry| !entry.diagnostic.nil? })
    end

    it "reports a snapshot cut short by its row limit" do
      snapshot = PC::Inspection.snapshot(limit: 1)
      snapshot.observations.size.should eq(1)
      snapshot.truncated?.should be_true
      snapshot.complete?.should be_false
    end

    it "reports a positively observed stopped state" do
      target = Process.new("/bin/sleep", ["30"])
      begin
        target.signal(Signal::STOP)
        deadline = PC::Wait::Deadline.after(5.seconds)
        loop do
          observation = PC::Inspection.snapshot.observations.find { |entry| entry.identity.pid == target.pid }
          if observation && observation.execution.stopped?
            observation.presence.present?.should be_true
            observation.termination.alive?.should be_true
            break
          end
          raise "native snapshot did not observe stopped target" if deadline.expired?
          deadline.pause
        end
      ensure
        target.signal(Signal::KILL)
        target.wait
      end
    end
  {% else %}
    it "refuses a platform without an inspection provider" do
      expect_raises(PC::Error::Unsupported) { PC::Inspection.snapshot }
    end
  {% end %}
end
