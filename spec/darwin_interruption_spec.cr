require "./spec_helper"

{% if flag?(:darwin) %}
  require "json"
  require "random/secure"

  if ENV["PROCESS_CONTROL_DARWIN_QUALIFICATION"]? == "1"
    describe "Darwin native signal interruption" do
      it "preserves exit events under signals and after an interrupted blocking control" do
        fixture = ENV["PROCESS_CONTROL_DARWIN_INTERRUPTION_FIXTURE"]
        directory = File.join(Dir.tempdir, "process-control-interruption-#{Random::Secure.hex(12)}")
        Dir.mkdir(directory, 0o700)
        path = File.join(directory, "signals")
        process = nil.as(Process?)
        owner = nil.as(PC::Handle?)
        collected = false
        begin
          File.open(path, "w+") do |signals|
            process = Process.new(fixture, output: Process::Redirect::Pipe, error: signals)
            owner = PC::Handle.open(process.pid, required: PC::Capability::Request.control)
            process.output.read_timeout = 30.seconds
            receipt = JSON.parse(process.output.gets.not_nil!)
            status = process.wait
            collected = true
            puts receipt.to_json
            status.success?.should be_true
            receipt["calls"].as_i64.should eq(2_000_000)
            receipt["empty"].as_i64.should eq(1_999_999)
            receipt["exits"].as_i64.should eq(1)
            receipt["eintr"].as_i64.should eq(0)
            receipt["unexpected"].as_i64.should eq(0)
            receipt["signals"].as_i64.should be > 0
            receipt["sender"].as_i64.should eq(1)
            receipt["target"].as_i64.should eq(1)
            receipt["blocking_result"].as_i64.should eq(-1)
            receipt["blocking_errno"].as_i64.should eq(Errno::EINTR.value)
            receipt["post_exits"].as_i64.should eq(1)
            receipt["post_sender"].as_i64.should eq(1)
            receipt["post_target"].as_i64.should eq(1)
            signals.size.should be > receipt["signals"].as_i64
          end
        ensure
          if child = process
            unless collected
              owner.try(&.kill)
              child.wait
            end
          end
          owner.try(&.close)
          File.delete(path) if File.exists?(path)
          Dir.delete(directory)
        end
      end
    end
  end
{% end %}
