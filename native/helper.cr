# Compile with -Dwithout_main. No Crystal.main, GC, fibers or managed exceptions.
{% unless flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  {% raise "The native helper supports macOS and Linux." %}
{% end %}

{% unless flag?(:aarch64) || flag?(:x86_64) %}
  {% raise "The native helper supports ARM64 and x86-64." %}
{% end %}

require "c/unistd"
require "c/fcntl"
require "c/dirent"
require "c/string"
require "c/signal"
require "c/sys/un"
require "c/sys/wait"
require "./helper/protocol"
require "./helper/descriptors"
require "./helper/signals"
require "./helper/owner"

module ProcessControl::Internal::Unix::Owner
  SIGNALS   = {{ flag?(:darwin) ? 32 : 65 }}
  DUPLICATE = {{ flag?(:darwin) ? 67 : 1030 }} # F_DUPFD_CLOEXEC from target headers

  lib Native
    {% if flag?(:darwin) %}
      alias Count = UInt32
    {% else %}
      alias Count = UInt64
    {% end %}

    struct Event
      fd : Int32
      events : Int16
      revents : Int16
    end

    fun poll(events : Event*, count : Count, timeout : Int32) : Int32
    fun execv(path : UInt8*, argv : UInt8**) : Int32
    fun sigprocmask(how : Int32, set : LibC::SigsetT*, old : LibC::SigsetT*) : Int32
  end
end

fun main(argc : Int32, argv : UInt8**) : Int32
  ProcessControl::Internal::Unix::Owner.run(argc, argv)
end
