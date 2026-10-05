#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_connector_openai_stability_integration.rb
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

TMP_ROOT = File.expand_path("../build/tmp", __dir__)
FileUtils.mkdir_p(TMP_ROOT)
SECRET = "pca05-stability-secret-marker"
COMMANDS_PER_BATCH = 20
PING_COMMANDS_PER_BATCH = 19
WARMUP_BATCHES = 5
RECONNECT_INTERVAL = 10
DEFAULT_BATCHES = 50
TOTAL_BATCHES = Integer(
  ENV.fetch("SONBAL_PCA05_STABILITY_BATCHES", DEFAULT_BATCHES.to_s),
  10
)
unless TOTAL_BATCHES.between?(WARMUP_BATCHES + 1, 500)
  abort "SONBAL_PCA05_STABILITY_BATCHES must be between 6 and 500"
end

MCP_META = {
  "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities" => {},
  "io.modelcontextprotocol/clientInfo" => {
    "name" => "sonbal-pca05-stability",
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


def linux_snapshot(pid)
  status = File.read("/proc/#{pid}/status", encoding: "UTF-8")
  rss_match = status.match(/^VmRSS:\s+(\d+)\s+kB$/)
  thread_match = status.match(/^Threads:\s+(\d+)$/)
  raise "Linux VmRSS is unavailable for PCA-05 stability" if rss_match.nil?
  raise "Linux thread count is unavailable for PCA-05 stability" if
    thread_match.nil?

  children_path = "/proc/#{pid}/task/#{pid}/children"
  children =
    File.read(children_path, encoding: "UTF-8").split.map do |value|
      Integer(value, 10)
    end

  fds =
    begin
      Dir.children("/proc/#{pid}/fd").length
    rescue Errno::EACCES
      :denied
    end

  {
    rss_kib: Integer(rss_match[1], 10),
    threads: Integer(thread_match[1], 10),
    fds: fds,
    children: children
  }
end


def wait_for_held_poll_close(socket, timeout:)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    raise "held PCA-05 stability poll was not cancelled" if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    ready = IO.select([socket], nil, nil, 0.1)
    next if ready.nil?

    peek = socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
    return if peek.nil? || peek == ""
    next if peek == :wait_readable

    raise "unexpected bytes on held PCA-05 stability poll"
  end
end


def validate_ping(response, expected_id)
  raise "ping response id changed" unless response.fetch("id") == expected_id
  structured = response.fetch("result").fetch("structuredContent")
  raise "ping version changed" unless
    structured.fetch("version") == SERVER_VERSION
  raise "ping revision changed" unless
    structured.fetch("revision") == SERVER_REVISION
end


def validate_run(response, expected_id, expected_output)
  raise "run response id changed" unless response.fetch("id") == expected_id
  result = response.fetch("result")
  raise "run response became MCP error" if result.fetch("isError")
  structured = result.fetch("structuredContent")
  raise "run response did not exit" unless
    structured.fetch("status") == "exited"
  raise "run response exit code changed" unless
    structured.fetch("exit_code") == 0
  stdout = structured.fetch("stdout")
  raise "run response encoding changed" unless
    stdout.fetch("encoding") == "utf8"
  raise "run response output changed" unless
    stdout.fetch("data") == expected_output
end


server = TCPServer.new("127.0.0.1", 0)
base_url = "http://127.0.0.1:#{server.addr[1]}"
errors = Queue.new
checkpoints = Queue.new
releases = Queue.new
held_poll_cancelled = false
disconnect_count = 0

Dir.mktmpdir("sonbal-pca05-stability-", TMP_ROOT) do |workspace|
  phase = :rotate_prepare
  operation_id = nil
  workspace_token = nil
  pending = {}
  completed_batches = 0
  current_batch = nil
  warmup_checkpoint_done = false
  disconnected_after_batch = nil

  server_thread = Thread.new do
    begin
      loop do
        socket = server.accept
        begin
          method, target, headers, body = read_request(socket)
          validate_common_headers(headers)
          poll_target =
            "/v1/tunnels/pca05-stability/poll?limit=20&timeout_ms=1000"

          if method == "GET"
            raise "stability poll target changed: #{target}" unless
              target == poll_target
            raise "provider polled before prior batch settled" unless
              pending.empty?

            if phase == :bulk &&
               completed_batches == WARMUP_BATCHES &&
               !warmup_checkpoint_done
              warmup_checkpoint_done = true
              checkpoints << :warmup
              release = releases.pop
              raise "unexpected warmup checkpoint release" unless
                release == :continue
            end

            if phase == :bulk && completed_batches == TOTAL_BATCHES
              checkpoints << :final
              wait_for_held_poll_close(socket, timeout: 15)
              held_poll_cancelled = true
              break
            end

            if phase == :bulk &&
               completed_batches.positive? &&
               (completed_batches % RECONNECT_INTERVAL).zero? &&
               disconnected_after_batch != completed_batches
              disconnected_after_batch = completed_batches
              disconnect_count += 1
              next
            end

            commands = []
            case phase
            when :rotate_prepare
              request_id = "rotate-prepare"
              jsonrpc = tool_call(
                request_id,
                "rotate_workspace_token",
                "root" => workspace
              )
              pending["provider-rotate-prepare"] = {
                kind: :rotate_prepare,
                json_id: request_id
              }
              commands << provider_command(
                "provider-rotate-prepare",
                "shard-rotate-prepare",
                jsonrpc
              )
            when :rotate_commit
              request_id = "rotate-commit"
              jsonrpc = tool_call(
                request_id,
                "rotate_workspace_token",
                "root" => workspace,
                "operation_id" => operation_id
              )
              pending["provider-rotate-commit"] = {
                kind: :rotate_commit,
                json_id: request_id
              }
              commands << provider_command(
                "provider-rotate-commit",
                "shard-rotate-commit",
                jsonrpc
              )
            when :bulk
              current_batch = completed_batches + 1

              1.upto(PING_COMMANDS_PER_BATCH) do |index|
                json_id = "batch-#{current_batch}-ping-#{index}"
                provider_id = "provider-#{json_id}"
                pending[provider_id] = {
                  kind: :ping,
                  json_id: json_id
                }
                commands << provider_command(
                  provider_id,
                  "shard-#{json_id}",
                  tool_call(json_id, "ping")
                )
              end

              run_json_id = "batch-#{current_batch}-run"
              run_provider_id = "provider-#{run_json_id}"
              output = "pca05-batch-#{current_batch}"
              pending[run_provider_id] = {
                kind: :run,
                json_id: run_json_id,
                output: output
              }
              commands << provider_command(
                run_provider_id,
                "shard-#{run_json_id}",
                tool_call(
                  run_json_id,
                  "run_process",
                  "workspace_token" => workspace_token,
                  "argv" => ["/usr/bin/printf", output],
                  "resolution" => "exact_path",
                  "cwd" => workspace,
                  "timeout_ms" => 2_000
                )
              )
              raise "stability batch width changed" unless
                commands.length == COMMANDS_PER_BATCH
            else
              raise "unexpected stability phase #{phase.inspect}"
            end

            write_response(
              socket,
              200,
              "OK",
              JSON.generate("commands" => commands)
            )
          elsif method == "POST"
            raise "stability response target changed" unless
              target == "/v1/tunnels/pca05-stability/response"
            raise "stability response exposed credential" if
              body.include?(SECRET)

            payload = JSON.parse(body)
            provider_id = payload.fetch("request_id")
            expected = pending.delete(provider_id)
            raise "unexpected stability response #{provider_id}" if
              expected.nil?
            raise "stability shard token changed" unless
              one_header(
                headers,
                "X-Tunnel-Shard-Token"
              ) == provider_id.sub("provider-", "shard-")
            raise "stability response code changed" unless
              payload.fetch("resp_code") == 200
            raise "stability response type changed" unless
              payload.fetch("resp_type") == "jsonrpc_response"

            response = payload.fetch("resp_json")
            case expected.fetch(:kind)
            when :rotate_prepare
              structured =
                response.fetch("result").fetch("structuredContent")
              raise "stability token prepare changed" unless
                structured.fetch("status") == "prepared"
              operation_id = structured.fetch("operation_id")
              phase = :rotate_commit
            when :rotate_commit
              structured =
                response.fetch("result").fetch("structuredContent")
              raise "stability token commit changed" unless
                structured.fetch("status") == "rotated"
              workspace_token = structured.fetch("workspace_token")
              phase = :bulk
            when :ping
              validate_ping(response, expected.fetch(:json_id))
            when :run
              validate_run(
                response,
                expected.fetch(:json_id),
                expected.fetch(:output)
              )
            else
              raise "unexpected stability response kind"
            end

            if phase == :bulk &&
               !current_batch.nil? &&
               pending.empty?
              completed_batches += 1
              current_batch = nil
            end

            write_response(socket, 200, "OK", '{"status":"ok"}')
          else
            raise "unexpected stability HTTP method #{method}"
          end
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue StandardError => error
      errors << error
      checkpoints << :error
    end
  end

  config = Tempfile.new(["sonbal-pca05-stability-", ".json"], TMP_ROOT)
  credential = Tempfile.new("sonbal-pca05-stability-secret-", TMP_ROOT)

  begin
    config.write(
      JSON.generate(
        "tunnel_id" => "pca05-stability",
        "poll_limit" => 20,
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
    warmup = nil
    final = nil

    Open3.popen3(
      environment,
      fixture,
      plugin,
      config.path,
      credential.path,
      "completed"
    ) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new do
        stdout.read
      rescue IOError
        ""
      end
      stderr_reader = Thread.new do
        stderr.read
      rescue IOError
        ""
      end

      first = Timeout.timeout(60) { checkpoints.pop }
      raise errors.pop unless first == :warmup
      warmup = linux_snapshot(wait_thread.pid)
      raise "warmup process execution did not settle" unless
        warmup.fetch(:children).empty?
      releases << :continue

      second = Timeout.timeout(120) { checkpoints.pop }
      raise errors.pop unless second == :final
      final = linux_snapshot(wait_thread.pid)
      raise "final process execution did not settle" unless
        final.fetch(:children).empty?

      Process.kill("TERM", wait_thread.pid)
      child_status = Timeout.timeout(15) { wait_thread.value }
      child_stdout = stdout_reader.value
      child_stderr = stderr_reader.value
    rescue StandardError
      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Timeout.timeout(5) { wait_thread.value }
      rescue Timeout::Error
        nil
      end
      raise
    end

    raise "PCA-05 stability fixture failed: #{child_stderr}" unless
      child_status&.success?
    unless child_stdout.include?(
      "[PASS] PCA-05 Linux connector service completed"
    )
      raise "PCA-05 stability fixture success marker missing"
    end
    if child_stdout.include?(SECRET) || child_stderr.include?(SECRET)
      raise "PCA-05 stability diagnostics exposed credential"
    end

    unless final.fetch(:threads) == warmup.fetch(:threads)
      raise "PCA-05 stability thread count grew " \
        "#{warmup.fetch(:threads)} -> #{final.fetch(:threads)}"
    end
    unless final.fetch(:fds) == warmup.fetch(:fds)
      raise "PCA-05 stability descriptor count grew " \
        "#{warmup.fetch(:fds)} -> #{final.fetch(:fds)}"
    end

    rss_delta = final.fetch(:rss_kib) - warmup.fetch(:rss_kib)
    rss_limit = [4_096, (warmup.fetch(:rss_kib) / 4.0).ceil].max
    if rss_delta > rss_limit
      raise "PCA-05 stability RSS grew #{rss_delta} KiB, limit #{rss_limit}"
    end

    expected_disconnects =
      (TOTAL_BATCHES - 1) / RECONNECT_INTERVAL
    if disconnect_count != expected_disconnects
      raise "PCA-05 reconnect count changed " \
        "#{disconnect_count} != #{expected_disconnects}"
    end

    puts(
      "[PASS] PCA-05 stability resources " \
      "rss=#{warmup.fetch(:rss_kib)}->#{final.fetch(:rss_kib)}KiB " \
      "fds=#{warmup.fetch(:fds)} threads=#{warmup.fetch(:threads)} " \
      "reconnects=#{disconnect_count}"
    )
  ensure
    config.close!
    credential.close!
    server.close unless server.closed?
  end

  server_thread.join(15)
  raise "PCA-05 stability provider did not terminate" if server_thread.alive?
  raise errors.pop unless errors.empty?
end

raise "PCA-05 stability held poll did not cancel" unless held_poll_cancelled

total_commands = TOTAL_BATCHES * COMMANDS_PER_BATCH
puts(
  "[PASS] PCA-05 Linux repeated product-service stability " \
  "batches=#{TOTAL_BATCHES} commands=#{total_commands}"
)
