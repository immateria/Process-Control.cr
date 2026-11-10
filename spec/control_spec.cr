require "./spec_helper"

describe PC::Control do
  it "keeps a reported failure independent of postcondition evidence" do
    identity = PC::Identity.new(123)
    request = PC::Control::Kill::Request.new
    diagnostic = PC::Diagnostic.new("kill", "permission denied", native_domain: "errno", native_code: 1)
    result = PC::Control::Result.new(request, identity, PC::Control::Report::Failure.new(diagnostic), postcondition: :unknown)
    case report = result.disposition
    when PC::Control::Report::Failure
      report.diagnostic.native_code.should eq(1)
    else
      fail "wrong disposition"
    end
    result.postcondition.unknown?.should be_true
  end

  it "observes a pending operation without replaying it" do
    identity = PC::Identity.new(123)
    request = PC::Control::Kill::Request.new
    pending = PC::Control::Pending.new(request, identity, "test")
    early = pending.wait(deadline: PC::Wait::Deadline.after(Time::Span.zero))
    early.disposition.should be_a(PC::Control::Delivery::Unknown)
    accepted = PC::Control::Result.new(request, identity, PC::Control::Report::Success.new("accepted"))
    pending.publish(accepted)
    pending.wait.disposition.should be_a(PC::Control::Report::Success)
  end
end
