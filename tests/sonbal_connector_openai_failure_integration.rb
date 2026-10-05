#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_connector_openai_failure_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "json"
require "open3"
require "socket"
require "tempfile"
require "timeout"

fixture = File.expand_path(
  ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" }
)
plugin = File.expand_path(
  ARGV.fetch(1) { abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" }
)
abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" unless ARGV.length == 2

TMP_ROOT = File.expand_path("../build/tmp", __dir__)
FileUtils.mkdir_p(TMP_ROOT)
SECRET = "pca05-failure-secret-marker"


def read_request(socket)
  request_line = socket.gets("\n")
  raise "missing HTTP request line" if request_line.nil?

  method, target, version = request_line.strip.split(" ", 3)
  raise "malformed HTTP request line" if
    [method, target, version].any?(&:nil?)

  headers = Hash.new { |hash, key| hash[key] = [] }
  loop do
    line = socket.gets("\n")
    raise "truncated HTTP headers" if line.nil?
    break if line == "\r\n" || line == "\n"

    name, value = line.split(":", 2)
    raise "malformed HTTP header" if value.nil?
    headers[name.downcase] << value.strip
  end

  [method, target, headers]
end


def one_header(headers, name)
  values = headers[name.downcase]
  raise "missing #{name}" if values.nil? || values.empty?
  raise "duplicate #{name}" unless values.length == 1

  values.first
end


def write_response(socket, code, reason, body)
  headers =
    "HTTP/1.1 #{code} #{reason}\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Content-Type: application/json\r\n" \
    "Connection: close\r\n\r\n"
  socket.write(headers + body)
end


def run_failed_fixture(fixture, plugin, configuration, base_url)
  config = Tempfile.new(["sonbal-pca05-failure-", ".json"], TMP_ROOT)
  credential = Tempfile.new("sonbal-pca05-failure-secret-", TMP_ROOT)

  begin
    config.write(configuration)
    config.flush
    credential.write("#{SECRET}\n")
    credential.flush
    File.chmod(0o600, credential.path)

    environment = {
      "SONBAL_OPENAI_TEST_BASE_URL" => base_url,
      "HTTP_PROXY" => "http://127.0.0.1:1",
      "http_proxy" => "http://127.0.0.1:1",
      "NO_PROXY" => "",
      "no_proxy" => ""
    }

    stdout = nil
    stderr = nil
    status = nil
    Timeout.timeout(10) do
      stdout, stderr, status = Open3.capture3(
        environment,
        fixture,
        plugin,
        config.path,
        credential.path,
        "failed"
      )
    end

    raise "PCA-05 failure fixture returned nonzero: #{stderr}" unless
      status&.success?
    unless stdout.include?("[PASS] PCA-05 Linux connector service failed")
      raise "PCA-05 failure fixture success marker missing"
    end
    if stdout.include?(SECRET) || stderr.include?(SECRET)
      raise "PCA-05 failure diagnostics exposed credential"
    end
  ensure
    config.close!
    credential.close!
  end
rescue Timeout::Error
  raise "PCA-05 failure fixture did not settle within ten seconds"
end


invalid_config = JSON.generate("poll_limit" => 1)
run_failed_fixture(
  fixture,
  plugin,
  invalid_config,
  "http://127.0.0.1:1"
)

server = TCPServer.new("127.0.0.1", 0)
base_url = "http://127.0.0.1:#{server.addr[1]}"
errors = Queue.new
poll_count = 0
unexpected_retry = false

server_thread = Thread.new do
  begin
    socket = server.accept
    begin
      method, target, headers = read_request(socket)
      poll_count += 1
      expected =
        "/v1/tunnels/pca05-auth-failure/poll?limit=1&timeout_ms=1000"
      raise "authentication-failure method changed" unless method == "GET"
      raise "authentication-failure poll target changed" unless
        target == expected
      raise "authentication-failure bearer changed" unless
        one_header(headers, "Authorization") == "Bearer #{SECRET}"
      write_response(
        socket,
        401,
        "Unauthorized",
        '{"error":"invalid-runtime-key"}'
      )
    ensure
      socket.close unless socket.closed?
    end

    ready = IO.select([server], nil, nil, 0.75)
    unless ready.nil?
      retry_socket = server.accept
      retry_socket.close
      unexpected_retry = true
    end
  rescue StandardError => error
    errors << error
  end
end

begin
  configuration = JSON.generate(
    "tunnel_id" => "pca05-auth-failure",
    "poll_limit" => 1,
    "poll_timeout_ms" => 1_000
  )
  run_failed_fixture(fixture, plugin, configuration, base_url)
  server_thread.join(5)
  raise "authentication-failure server did not terminate" if
    server_thread.alive?
ensure
  server.close unless server.closed?
end

raise errors.pop unless errors.empty?
raise "authentication-failure poll was not observed" unless poll_count == 1
raise "non-retryable authentication failure was retried" if unexpected_retry

puts "[PASS] PCA-05 Linux connector service failure acceptance"
