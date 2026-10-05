# =============================================================================
# sonbal_connector_host_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "open3"
require "tempfile"

fixture, good_plugin, bad_plugin, missing_plugin = ARGV
abort "usage: #{$PROGRAM_NAME} FIXTURE GOOD BAD MISSING" unless ARGV.length == 4

TMP_ROOT = File.expand_path("../build/tmp", __dir__)
FileUtils.mkdir_p(TMP_ROOT)

def run_case(fixture, scenario, plugin, mode)
  Tempfile.create(["sonbal-connector-host-", ".cfg"], TMP_ROOT) do |file|
    file.binmode
    file.write(mode)
    file.flush

    stdout, stderr, status =
      Open3.capture3(fixture, scenario, plugin, file.path)

    unless status.success?
      warn stdout
      warn stderr
      abort "connector host scenario failed: #{scenario}"
    end

    expected = "[PASS] connector host #{scenario}"
    abort "missing success marker for #{scenario}" unless stdout.include?(expected)
  end
end

run_case(fixture, "missing-symbol", missing_plugin, "G")
run_case(fixture, "bad-abi", bad_plugin, "G")
run_case(fixture, "init-fail", good_plugin, "I")
run_case(fixture, "invalid-wakeup", good_plugin, "V")
run_case(fixture, "watch-fail", good_plugin, "W")
run_case(fixture, "finalize-fail", good_plugin, "F")
run_case(fixture, "start-fail", good_plugin, "S")
8.times { run_case(fixture, "good", good_plugin, "G") }

puts "[PASS] connector host dynamic lifecycle integration"
