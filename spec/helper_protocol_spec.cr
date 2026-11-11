require "./spec_helper"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  module Fixture
    def self.protocol_exit(socket : UNIXSocket, token : String, raw : UInt32) : Nil
      line = socket.gets.not_nil!
      parts = line.split
      parts[0, 3].should eq(["EXIT", token, raw.to_s])
      info = PC::Internal::Unix::Protocol.exit(parts)
      info.raw.should eq(raw)
      {% if flag?(:darwin) %}
        info.usage.not_nil!.max_rss_bytes.should be > 0
      {% else %}
        info.usage.should be_nil
      {% end %}
    end

    def self.protocol(script : String, &block : UNIXSocket, String ->) : Process::Status
      directory = "/tmp/process-control-protocol-#{Random::Secure.hex(10)}"
      Dir.mkdir(directory, 0o700)
      path = File.join(directory, "channel")
      server = UNIXServer.new(path)
      server.read_timeout = 5.seconds
      socket = nil.as(UNIXSocket?)
      process = nil.as(Process?)
      status = nil.as(Process::Status?)
      begin
        token = Random::Secure.hex(16)
        process = Process.new(PC::Platform::Unix::Helper.path, [path, token, "--", "/bin/sh", "-c", script],
          input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
        socket = server.accept
        socket.read_timeout = 5.seconds
        greeting = socket.gets.not_nil!.split
        greeting[0, 3].should eq(["HELLO", "2", token])
        socket << "START #{token}\n"
        socket.flush
        socket.gets.not_nil!.should start_with("STARTED #{token} ")
        yield socket, token
      ensure
        socket.try(&.close)
        server.close
        status = process.try(&.wait)
        File.delete(path) if File.exists?(path)
        Dir.delete(directory)
      end
      status.not_nil!
    end
  end

  describe "native helper protocol" do
    it "continues collecting when the peer cannot receive an acknowledgment" do
      marker = "/tmp/process-control-marker-#{Random::Secure.hex(10)}"
      begin
        status = Fixture.protocol("sleep 0.1; printf done > #{marker}; exit 37") do |socket, token|
          LibC.shutdown(socket.fd, 0).should eq(0)
          socket << "SIGNAL #{token} 1 #{Signal::CONT.value}\n"
          socket.flush
        end
        status.success?.should be_true
        File.read(marker).should eq("done")
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end

    it "echoes unsigned sequence boundaries without narrowing them" do
      Fixture.protocol("sleep 0.1; exit 37") do |socket, token|
        ["18446744073709551615", "0"].each do |sequence|
          socket << "SIGNAL #{token} #{sequence} #{Signal::CONT.value}\n"
          socket.flush
          socket.gets.should eq("ACK #{token} #{sequence} 0")
        end
        Fixture.protocol_exit(socket, token, 9472_u32)
      end
    end

    it "ignores a well-formed frame carrying the wrong session token" do
      Fixture.protocol("sleep 0.1; exit 37") do |socket, token|
        socket << "SIGNAL wrong-token 1 9\nSIGNAL #{token} 2 #{Signal::CONT.value}\n"
        socket.flush
        socket.gets.should eq("ACK #{token} 2 0")
        Fixture.protocol_exit(socket, token, 9472_u32)
      end
    end

    it "does not deliver a signal when the unsigned sequence overflows" do
      marker = "/tmp/process-control-marker-#{Random::Secure.hex(10)}"
      begin
        Fixture.protocol("sleep 0.1; printf done > #{marker}; exit 37") do |socket, token|
          socket << "SIGNAL #{token} 18446744073709551616 9\n"
          socket.flush
          socket.gets.should be_nil
        end
        File.read(marker).should eq("done")
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end

    it "keeps a real exit 127 distinct from native exec failure" do
      Fixture.protocol("exit 127") do |socket, token|
        Fixture.protocol_exit(socket, token, 32512_u32)
      end
    end

    it "rejects an embedded NUL instead of executing its numeric prefix" do
      marker = "/tmp/process-control-marker-#{Random::Secure.hex(10)}"
      begin
        Fixture.protocol("sleep 0.1; printf done > #{marker}; exit 37") do |socket, token|
          socket << "SIGNAL #{token} 1 9\0ignored\n"
          socket.flush
          begin
            socket.gets.should be_nil
          rescue ex : IO::Error
            # Linux may reset a socket closed with unread trailing bytes.
            # The target-continuation assertion below remains mandatory.
            ex.os_error.should eq(Errno::ECONNRESET)
          end
        end
        File.read(marker).should eq("done")
      ensure
        File.delete(marker) if File.exists?(marker)
      end
    end
  end
{% end %}
