require "./spec_helper"

describe PC::Identity do
  it "keeps contradictory and insufficient generation evidence distinct" do
    scope = PC::Identity::Scope.new("test", boot: "boot")
    first = PC::Identity.new(123, scope, PC::Identity::Generation.new("test", "first"))
    same = PC::Identity.new(123, scope, PC::Identity::Generation.new("test", "first"))
    reused = PC::Identity.new(123, scope, PC::Identity::Generation.new("test", "second"))
    unknown = PC::Identity.new(123, scope)
    first.compare(same).consistent?.should be_true
    first.compare(reused).different?.should be_true
    first.compare(unknown).indeterminate?.should be_true
    first.same_pid?(reused).should be_true
    expect_raises(ArgumentError) { PC::Identity.new(0) }
    expect_raises(ArgumentError) { PC::Identity.new(-1) }
  end
end

describe PC::Observation do
  it "does not conflate presence, termination and execution" do
    identity = PC::Identity.new(123)
    zombie = PC::Observation.new(identity, presence: :present, termination: :terminated, execution: :zombie)
    zombie.presence.present?.should be_true
    zombie.termination.terminated?.should be_true
    expect_raises(ArgumentError) do
      PC::Observation.new(identity, presence: :absent, termination: :alive)
    end
  end
end

describe PC::Control::Release::Result do
  it "retains separately retryable records when uncertainty dominates" do
    records = [
      PC::Control::Release::Record.new("uncertain", :uncertain),
      PC::Control::Release::Record.new("retained", :retryable),
    ]
    result = PC::Control::Release::Result.new(records)
    records.clear
    result.state.uncertain?.should be_true
    result.records.size.should eq(2)
    result.records.clear
    result.records.size.should eq(2)
  end
end
