{% if flag?(:windows) %}
  require "./support/windows"
{% elsif flag?(:linux) && !flag?(:android) %}
  require "./support/linux"
{% end %}

require "spec"
require "../src/process-control"

alias PC = ProcessControl
