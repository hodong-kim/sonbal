#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_connector_openai_e2e_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "json"
require "open3"
require "socket"
require "tempfile"
require "timeout"
require "tmpdir"

fixture = File.expand_path(
  ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" }
)
plugin = File.expand_path(
  ARGV.fetch(1) { abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" }
)
abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" unless ARGV.length == 2

SECRET = "pca05-e2e-secret-marker"
EXPECTED_TOOLS = %w[
  ping
  rotate_workspace_token
  run_process
  start_process
  poll_process
  cancel_process
  read_file
].freeze
MCP_META = {
  "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities" => {},
  "io.modelcontextprotocol/clientInfo" => {
    "name" => "sonbal-pca05-e2e",
    "version" => "1"
  }
}.freeze


def release_identity_value(name)
  path = File.expand_path("../src/sonbal-release_identity.ads", __dir__)
  source = File.read(path, encoding: "UTF-8")
  pattern =
    /^\s*#{Regexp.escape(name)}\s*:\s*constant\s+String\s*:=\s*"([^"]+)";/
  match = source.match(pattern)
  raise "missing release identity #{name}" if match.nil?

  match[1]
end


SERVER_VERSION = release_identity_value("Version")
SERVER_REVISION = release_identity_value("Revision")


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

  length = Integer(headers.fetch("content-length", ["0"]).first, 10)
  body = length.zero? ? "" : socket.read(length)
  raise "truncated HTTP body" if body.nil? || body.bytesize != length

  [method, target, headers, body]
end


def one_header(headers, name)
  values = headers[name.downcase]
  raise "missing #{name}" if values.nil? || values.empty?
  raise "duplicate #{name}" unless values.length == 1

  values.first
end


def validate_common_headers(headers)
  raise "bearer credential changed" unless
    one_header(headers, "Authorization") == "Bearer #{SECRET}"
  raise "client name changed" unless
    one_header(headers, "X-Tunnel-Client-Name") == "sonbal"
  raise "client version changed" unless
    one_header(headers, "X-Tunnel-Client-Version") == "1"
  raise "wire version changed" unless
    one_header(
      headers,
      "X-Tunnel-Client-Wire-Protocol-Version"
    ) == "2026-08-25"
end


def write_response(socket, code, reason, body = "")
  headers =
    "HTTP/1.1 #{code} #{reason}\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Connection: close\r\n"
  headers += "Content-Type: application/json\r\n" unless body.empty?
  socket.write(headers + "\r\n" + body)
end


def tool_call(id, name, arguments = {})
  {
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => {
      "_meta" => MCP_META,
      "name" => name,
      "arguments" => arguments
    }
  }
end


def tools_list(id)
  {
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/list",
    "params" => {"_meta" => MCP_META}
  }
end


def provider_command(request_id, shard, jsonrpc)
  {
    "request_id" => request_id,
    "shard_token" => shard,
    "command_type" => "jsonrpc",
    "channel" => "main",
    "created_at" => "2026-10-01T00:00:00Z",
    "jsonrpc" => jsonrpc
  }
end


def structured_content(response, expected_status, is_error: false)
  result = response.fetch("result")
  raise "tool error flag changed" unless result.fetch("isError") == is_error
  structured = result.fetch("structuredContent")
  raise "tool status changed" unless
    structured.fetch("status") == expected_status

  structured
end


def next_jsonrpc(step, state, workspace, sequence)
  id = "pca05-#{step}-#{sequence}"

  request =
    case step
    when :tools_list
      tools_list(id)
    when :ping
      tool_call(id, "ping")
    when :rotate_prepare
      tool_call(id, "rotate_workspace_token", "root" => workspace)
    when :rotate_commit
      tool_call(
        id,
        "rotate_workspace_token",
        "root" => workspace,
        "operation_id" => state.fetch(:operation_id)
      )
    when :read_file
      tool_call(
        id,
        "read_file",
        "workspace_token" => state.fetch(:workspace_token),
        "path" => "read-file.txt",
        "maximum_bytes" => 64
      )
    when :run_process
      tool_call(
        id,
        "run_process",
        "workspace_token" => state.fetch(:workspace_token),
        "argv" => ["/usr/bin/printf", "pca05-sync"],
        "resolution" => "exact_path",
        "cwd" => workspace,
        "timeout_ms" => 2_000
      )
    when :start_process
      tool_call(
        id,
        "start_process",
        "workspace_token" => state.fetch(:workspace_token),
        "argv" => [
          "/bin/sh",
          "-c",
          "printf pca05-job; exec /bin/sleep 30"
        ],
        "resolution" => "exact_path",
        "cwd" => workspace,
        "timeout_ms" => 30_000
      )
    when :poll_until_output
      tool_call(
        id,
        "poll_process",
        "job_id" => state.fetch(:job_id),
        "cursor" => state.fetch(:initial_cursor)
      )
    when :poll_replay
      tool_call(
        id,
        "poll_process",
        "job_id" => state.fetch(:job_id),
        "cursor" => state.fetch(:initial_cursor)
      )
    when :cancel_process
      tool_call(
        id,
        "cancel_process",
        "job_id" => state.fetch(:job_id)
      )
    when :poll_until_cancelled
      tool_call(
        id,
        "poll_process",
        "job_id" => state.fetch(:job_id),
        "cursor" => state.fetch(:cancel_cursor)
      )
    else
      raise "unexpected PCA-05 step #{step.inspect}"
    end

  [id, request]
end


def consume_response(step, response, state)
  case step
  when :tools_list
    tools = response.fetch("result").fetch("tools")
    names = tools.map { |tool| tool.fetch("name") }
    raise "unexpected PCA-05 tool surface: #{names.inspect}" unless
      names == EXPECTED_TOOLS
    :ping
  when :ping
    structured = response.fetch("result").fetch("structuredContent")
    raise "ping version changed" unless
      structured.fetch("version") == SERVER_VERSION
    raise "ping revision changed" unless
      structured.fetch("revision") == SERVER_REVISION
    :rotate_prepare
  when :rotate_prepare
    structured = structured_content(response, "prepared")
    state[:operation_id] = structured.fetch("operation_id")
    :rotate_commit
  when :rotate_commit
    structured = structured_content(response, "rotated")
    state[:workspace_token] = structured.fetch("workspace_token")
    :read_file
  when :read_file
    structured = structured_content(response, "ok")
    content = structured.fetch("content")
    raise "read_file encoding changed" unless content.fetch("encoding") == "utf8"
    raise "read_file content changed" unless
      content.fetch("data") == "pca05-read-file"
    raise "read_file byte count changed" unless
      content.fetch("bytes") == "pca05-read-file".bytesize
    raise "read_file file size changed" unless
      structured.fetch("file_size") == "pca05-read-file".bytesize
    raise "read_file did not report EOF" unless structured.fetch("eof")
    raise "read_file revision changed shape" unless
      structured.fetch("revision").match?(/\Ar1-[0-9a-f]{96}\z/)
    :run_process
  when :run_process
    structured = structured_content(response, "exited")
    raise "synchronous process exit code changed" unless
      structured.fetch("exit_code") == 0
    stdout = structured.fetch("stdout")
    raise "synchronous process encoding changed" unless
      stdout.fetch("encoding") == "utf8"
    raise "synchronous process output changed" unless
      stdout.fetch("data") == "pca05-sync"
    :start_process
  when :start_process
    structured = structured_content(response, "running")
    state[:job_id] = structured.fetch("job_id")
    state[:initial_cursor] = structured.fetch("cursor")
    :poll_until_output
  when :poll_until_output
    structured = structured_content(response, "running")
    stdout = structured.fetch("stdout")
    if stdout.fetch("bytes").positive?
      raise "server-owned job encoding changed" unless
        stdout.fetch("encoding") == "utf8"
      raise "server-owned job output changed" unless
        stdout.fetch("data") == "pca05-job"
      state[:poll_snapshot] = structured
      state[:cancel_cursor] = structured.fetch("next_cursor")
      :poll_replay
    else
      :poll_until_output
    end
  when :poll_replay
    structured = structured_content(response, "running")
    snapshot = state.fetch(:poll_snapshot)
    unless structured.fetch("stdout") == snapshot.fetch("stdout") &&
           structured.fetch("stderr") == snapshot.fetch("stderr") &&
           structured.fetch("next_cursor") == snapshot.fetch("next_cursor")
      raise "same-cursor poll replay changed retained output"
    end
    :cancel_process
  when :cancel_process
    structured_content(response, "cancelling")
    :poll_until_cancelled
  when :poll_until_cancelled
    structured = response.fetch("result").fetch("structuredContent")
    case structured.fetch("status")
    when "running"
      state[:cancel_cursor] = structured.fetch("next_cursor")
      :poll_until_cancelled
    when "cancelled"
      raise "cancelled result became an MCP error" if
        response.fetch("result").fetch("isError")
      :done
    else
      raise "unexpected cancellation terminal status " \
        "#{structured.fetch("status").inspect}"
    end
  else
    raise "unexpected PCA-05 response step #{step.inspect}"
  end
end


def terminate_process(pid)
  Process.kill("TERM", pid)
rescue Errno::ESRCH
  nil
end


tmp_root = File.expand_path("../build/tmp", __dir__)
FileUtils.mkdir_p(tmp_root)
server = TCPServer.new("127.0.0.1", 0)
base_url = "http://127.0.0.1:#{server.addr[1]}"
errors = Queue.new
flow_ready = Queue.new
held_poll_cancelled = false
poll_count = 0

Dir.mktmpdir("sonbal-pca05-e2e-", tmp_root) do |workspace|
  File.binwrite(File.join(workspace, "read-file.txt"), "pca05-read-file")
  state = {}
  step = :tools_list
  sequence = 0
  expected = nil

  server_thread = Thread.new do
    begin
      loop do
        socket = server.accept
        begin
          method, target, headers, body = read_request(socket)
          validate_common_headers(headers)
          expected_target =
            "/v1/tunnels/pca05-e2e/poll?limit=1&timeout_ms=1000"

          if method == "GET"
            raise "poll target changed: #{target}" unless
              target == expected_target

            poll_count += 1
            if poll_count == 1
              next
            end

            if step == :done
              flow_ready << :ready
              deadline =
                Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8.0
              loop do
                raise "held PCA-05 poll was not cancelled" if
                  Process.clock_gettime(
                    Process::CLOCK_MONOTONIC
                  ) >= deadline

                ready = IO.select([socket], nil, nil, 0.1)
                next if ready.nil?

                peek = socket.recv_nonblock(
                  1,
                  Socket::MSG_PEEK,
                  exception: false
                )
                if peek.nil? || peek == ""
                  held_poll_cancelled = true
                  break
                elsif peek == :wait_readable
                  next
                else
                  raise "unexpected bytes on held PCA-05 poll"
                end
              end
              break
            end

            sequence += 1
            json_id, jsonrpc =
              next_jsonrpc(step, state, workspace, sequence)
            provider_id = "provider-#{sequence}"
            shard = "shard-#{sequence}"
            expected = {
              provider_id: provider_id,
              shard: shard,
              json_id: json_id,
              step: step
            }
            response = JSON.generate(
              "commands" => [
                provider_command(provider_id, shard, jsonrpc)
              ]
            )
            write_response(socket, 200, "OK", response)
          elsif method == "POST"
            raise "unexpected response target #{target}" unless
              target == "/v1/tunnels/pca05-e2e/response"
            raise "provider response arrived without command" if expected.nil?
            if body.include?(SECRET)
              raise "credential leaked into response body"
            end

            payload = JSON.parse(body)
            raise "provider request id changed" unless
              payload.fetch("request_id") == expected.fetch(:provider_id)
            raise "provider shard changed" unless
              one_header(
                headers,
                "X-Tunnel-Shard-Token"
              ) == expected.fetch(:shard)
            raise "provider response code changed" unless
              payload.fetch("resp_code") == 200
            raise "provider response type changed" unless
              payload.fetch("resp_type") == "jsonrpc_response"

            response = payload.fetch("resp_json")
            raise "MCP response id changed" unless
              response.fetch("id") == expected.fetch(:json_id)

            step = consume_response(expected.fetch(:step), response, state)
            expected = nil
            write_response(socket, 200, "OK", '{"status":"ok"}')
          else
            raise "unexpected PCA-05 HTTP method #{method}"
          end
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue StandardError => error
      errors << error
      flow_ready << :error
    end
  end

  config = Tempfile.new(
    ["sonbal-pca05-config-", ".json"],
    tmp_root
  )
  credential = Tempfile.new("sonbal-pca05-credential-", tmp_root)

  begin
    config.write(
      JSON.generate(
        "tunnel_id" => "pca05-e2e",
        "poll_limit" => 1,
        "poll_timeout_ms" => 1_000
      )
    )
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

    child_stdout = nil
    child_stderr = nil
    child_status = nil

    Open3.popen3(
      environment,
      fixture,
      plugin,
      config.path,
      credential.path,
      "completed"
    ) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }

      ready = Timeout.timeout(30) { flow_ready.pop }
      raise errors.pop unless ready == :ready

      terminate_process(wait_thread.pid)
      child_status = Timeout.timeout(15) { wait_thread.value }
      child_stdout = stdout_reader.value
      child_stderr = stderr_reader.value
    rescue Timeout::Error
      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
      raise
    end

    raise "PCA-05 fixture failed: #{child_stderr}" unless
      child_status&.success?
    unless child_stdout.include?(
      "[PASS] PCA-05 Linux connector service completed"
    )
      raise "PCA-05 fixture success marker missing"
    end
    if child_stdout.include?(SECRET) || child_stderr.include?(SECRET)
      raise "PCA-05 service output exposed credential"
    end
  ensure
    config.close!
    credential.close!
    server.close unless server.closed?
  end

  server_thread.join(10)
  raise "PCA-05 provider thread did not terminate" if server_thread.alive?
  raise errors.pop unless errors.empty?
end

raise "PCA-05 reconnect path was not exercised" if poll_count < 2
raise "PCA-05 held poll did not cancel on service shutdown" unless
  held_poll_cancelled

puts "[PASS] PCA-05 isolated seven-tool connector E2E"
