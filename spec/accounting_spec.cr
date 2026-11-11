require "./spec_helper"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  module Fixture::Accounting
    def self.frame(raw = 37 << 8) : String
      "EXIT accounting-token #{raw} DARWIN 3 999999 5 6 " + (11_i64..24_i64).join(" ") + "\n"
    end

    def self.receive(frame : String) : PC::Spawn::Status::Source
      left, right = UNIXSocket.pair
      session = PC::Internal::Unix::Session.new(left, "accounting-token", Process.pid, 32)
      begin
        right << frame
        right.flush
        right.close
        result = session.source.wait_exit(deadline: PC::Wait::Deadline.after(2.seconds))
        result.state.expired?.should be_false
        session.source
      ensure
        right.close unless right.closed?
        left.close unless left.closed?
      end
    end
  end

  describe "terminal child accounting" do
    it "preserves every counter and both CPU times with the collected status" do
      source = Fixture::Accounting.receive(Fixture::Accounting.frame)
      info = source.latest.not_nil!.info.not_nil!
      info.code.should eq(37_u32)
      usage = info.usage.not_nil!
      usage.domain.should eq("darwin.wait4")
      usage.user.seconds.should eq(3_i64)
      usage.user.microseconds.should eq(999_999)
      usage.user.to_span.should eq(3.seconds + 999_999.microseconds)
      usage.system.seconds.should eq(5_i64)
      usage.system.microseconds.should eq(6)
      {usage.max_rss_bytes, usage.shared_memory, usage.data_memory, usage.stack_memory,
       usage.reclaims, usage.faults, usage.swaps, usage.input_blocks, usage.output_blocks,
       usage.sent, usage.received, usage.signals, usage.voluntary_switches,
       usage.involuntary_switches}.to_a.should eq((11_i64..24_i64).to_a)
      3.times do
        repeated = source.wait_exit(deadline: PC::Wait::Deadline.after(Time::Span.zero)).info.not_nil!
        repeated.code.should eq(37_u32)
        repeated.usage.not_nil!.involuntary_switches.should eq(24_i64)
      end
    end

    it "keeps signal death and unsupported accounting distinct from a measured zero" do
      signaled = Fixture::Accounting.receive(Fixture::Accounting.frame(15)).latest.not_nil!.info.not_nil!
      signaled.signal.should eq(15)
      signaled.usage.should_not be_nil
      absent = Fixture::Accounting.receive("EXIT accounting-token 0 NONE\n").latest.not_nil!.info.not_nil!
      absent.success?.should be_true
      absent.usage.should be_nil
      PC::Wait::Exit::Info.posix(0).usage.should be_nil
    end

    it "accepts full-width counters in a frame larger than the old transport bound" do
      values = (["9223372036854775807", "999999"] * 2) + Array.new(14, "9223372036854775807")
      frame = "EXIT accounting-token 9472 DARWIN #{values.join(" ")}\n"
      frame.bytesize.should be > 192
      frame.bytesize.should be < PC::Internal::Unix::Protocol::FRAME_LIMIT
      info = Fixture::Accounting.receive(frame).latest.not_nil!.info.not_nil!
      info.usage.not_nil!.user.seconds.should eq(Int64::MAX)
      info.usage.not_nil!.max_rss_bytes.should eq(Int64::MAX)
      info.usage.not_nil!.involuntary_switches.should eq(Int64::MAX)
    end

    it "refuses incomplete, overflowing and invalid accounting without publishing status" do
      valid = Fixture::Accounting.frame
      fields = valid.split
      invalid = [
        valid.chomp,
        valid.sub("accounting-token", "other-token"),
        "EXIT accounting-token 9472\n",
        "EXIT accounting-token 9472 UNKNOWN\n",
        "EXIT accounting-token 9472 NONE 1\n",
        valid.sub("999999", "1000000"),
        valid.sub("999999", "-1"),
        valid.sub("999999", "+1"),
        valid.sub("999999", "18446744073709551616"),
        valid.sub("9472", "4294967296"),
        valid.sub("9472", "127"),
        fields[0...-1].join(" ") + "\n",
        valid.chomp + " 25\n",
        "EXIT accounting-token 0 NONE" + " " * 512 + "\n",
      ]
      overflowing = fields.dup
      overflowing[8] = "9223372036854775808"
      invalid << overflowing.join(" ") + "\n"
      invalid.each do |frame|
        result = Fixture::Accounting.receive(frame).latest.not_nil!
        result.state.failed?.should be_true
        result.info.should be_nil
        result.failure.not_nil!.error.should be_a(PC::Wait::Collection::Failed)
      end
    end
  end
{% end %}
