# =============================================================================
# sonbal_connector_openai_integration.rb
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
FileUtils.mkdir_p(TMP_ROOT)

def run_case(fixture, plugin, scenario, configuration, credential)
  Tempfile.create(
    ["sonbal-openai-config-", ".json"], TMP_ROOT
  ) do |config_file|
    Tempfile.create(
      ["sonbal-openai-credential-", ".key"], TMP_ROOT
    ) do |credential_file|
      config_file.binmode
      config_file.write(configuration)
      config_file.flush

      credential_file.binmode
      credential_file.write(credential)
      credential_file.flush

      stdout = nil
      stderr = nil
      status = nil

      Timeout.timeout(10) do
        stdout, stderr, status = Open3.capture3(
          fixture,
          scenario,
          plugin,
          config_file.path,
          credential_file.path
        )
      end

      unless status.success?
        warn stdout
        warn stderr
        abort "OpenAI connector scenario failed: #{scenario}"
      end

      expected = "[PASS] OpenAI connector #{scenario}"
      abort "missing success marker for #{scenario}" unless
        stdout.include?(expected)
    end
  end
rescue Timeout::Error
  abort "OpenAI connector scenario timed out: #{scenario}"
end

valid_configuration =
  '{"tunnel_id":"tunnel_test","poll_limit":7,"poll_timeout_ms":30000}'

run_case(
  fixture,
  plugin,
  "initialize-finalize",
  valid_configuration,
  "sk-test-runtime-key\n"
)

run_case(
  fixture,
  plugin,
  "invalid-config",
  '{"poll_limit":1}',
  "sk-test-runtime-key\n"
)

run_case(
  fixture,
  plugin,
  "invalid-config",
  '{"tunnel_id":""}',
  "sk-test-runtime-key\n"
)

run_case(
  fixture,
  plugin,
  "invalid-credential",
  valid_configuration,
  "\n"
)

run_case(
  fixture,
  plugin,
  "oversize-config",
  "x" * 8193,
  "sk-test-runtime-key\n"
)

run_case(
  fixture,
  plugin,
  "oversize-credential",
  valid_configuration,
  "x" * 1025
)

puts "[PASS] OpenAI connector initialization boundary integration"
