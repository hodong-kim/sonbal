# =============================================================================
# sonbal_connector_server_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "open3"
require "tempfile"
require "timeout"

fixture, plugin = ARGV
abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" unless ARGV.length == 2

TMP_ROOT = File.expand_path("../build/tmp", __dir__)
FIXTURE_WATCHDOG_SECONDS = 25
FileUtils.mkdir_p(TMP_ROOT)

def run_case(fixture, plugin, scenario, mode)
  Tempfile.create(["sonbal-connector-server-", ".cfg"], TMP_ROOT) do |file|
    file.binmode
    file.write(mode)
    file.flush

    stdout = nil
    stderr = nil
    status = nil

    Timeout.timeout(FIXTURE_WATCHDOG_SECONDS) do
      stdout, stderr, status =
        Open3.capture3(fixture, scenario, plugin, file.path)
    end

    unless status.success?
      warn stdout
      warn stderr
      abort "connector server scenario failed: #{scenario}"
    end

    expected = "[PASS] connector server #{scenario}"
    abort "missing success marker for #{scenario}" unless stdout.include?(expected)
  end
rescue Timeout::Error
  abort "connector server scenario timed out: #{scenario}"
end

run_case(fixture, plugin, "request", "R")
run_case(fixture, plugin, "backpressure", "B")
run_case(fixture, plugin, "backpressure-abandonment", "X")
run_case(fixture, plugin, "abandonment", "A")
run_case(fixture, plugin, "shutdown-active", "Q")
run_case(fixture, plugin, "finalize-retry", "Y")
run_case(fixture, plugin, "notification", "N")
run_case(fixture, plugin, "server-owned-job", "J")

puts "[PASS] connector server request-flow integration"
