require "./spec_helper"

{% if flag?(:darwin) || (flag?(:linux) && !flag?(:android)) %}
  describe PC::Platform::Unix::Helper do
    it "keeps binaries for different compiler, target and source inputs separate" do
      first = PC::Platform::Unix::Helper.fingerprint("source a", "1.21.0", "aarch64-darwin")
      first.should_not eq(PC::Platform::Unix::Helper.fingerprint("source b", "1.21.0", "aarch64-darwin"))
      first.should_not eq(PC::Platform::Unix::Helper.fingerprint("source a", "1.22.2", "aarch64-darwin"))
      first.should_not eq(PC::Platform::Unix::Helper.fingerprint("source a", "1.21.0", "x86_64-darwin"))
    end
  end
{% end %}
