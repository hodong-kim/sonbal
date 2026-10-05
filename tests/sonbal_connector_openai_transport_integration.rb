# =============================================================================
# sonbal_connector_openai_transport_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "socket"
require "timeout"

executable = File.expand_path(
  ARGV.fetch(0) do
    abort "usage: #{$PROGRAM_NAME} TRANSPORT_TEST_EXECUTABLE"
  end
)
abort "usage: #{$PROGRAM_NAME} TRANSPORT_TEST_EXECUTABLE" unless ARGV.length == 1

COMMAND_BODY = JSON.generate(
  "commands" => [
    {
      "request_id" => "req_queue",
      "shard_token" => "shard-queue",
      "command_type" => "jsonrpc",
      "channel" => "main",
      "created_at" => "2026-09-30T00:00:00Z",
      "future_padding" => ("x" * 5000),
      "jsonrpc" => {
        "jsonrpc" => "2.0",
        "id" => "queue-ping",
        "method" => "tools/call",
        "params" => {
          "_meta" => {
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => {},
            "io.modelcontextprotocol/clientInfo" => {
              "name" => "queue-fixture",
              "version" => "1"
            }
          },
          "name" => "ping",
          "arguments" => {}
        }
      }
    },
    {
      "request_id" => "req_queued_expiry",
      "shard_token" => "shard-queued-expiry",
      "command_type" => "jsonrpc",
      "channel" => "main",
      "created_at" => "2026-09-30T00:00:00Z",
      "response_timeout" => "150ms",
      "future_padding" => ("x" * 5000),
      "jsonrpc" => {
        "jsonrpc" => "2.0",
        "id" => "queued-expiry-ping",
        "method" => "tools/call",
        "params" => {
          "_meta" => {
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => {},
            "io.modelcontextprotocol/clientInfo" => {
              "name" => "queued-expiry-fixture",
              "version" => "1"
            }
          },
          "name" => "ping",
          "arguments" => {}
        }
      }
    },
    {
      "request_id" => "req_deadline",
      "shard_token" => "shard-deadline",
      "command_type" => "jsonrpc",
      "channel" => "main",
      "created_at" => "2026-09-30T00:00:00Z",
      "response_timeout" => "1250ms",
      "future_padding" => ("x" * 5000),
      "jsonrpc" => {
        "jsonrpc" => "2.0",
        "id" => "deadline-ping",
        "method" => "tools/call",
        "params" => {
          "_meta" => {
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => {},
            "io.modelcontextprotocol/clientInfo" => {
              "name" => "deadline-fixture",
              "version" => "1"
            }
          },
          "name" => "ping",
          "arguments" => {}
        }
      }
    },
    {
      "request_id" => "req_after",
      "shard_token" => "shard-after",
      "command_type" => "jsonrpc",
      "channel" => "main",
      "created_at" => "2026-09-30T00:00:00Z",
      "future_padding" => ("x" * 5000),
      "jsonrpc" => {
        "jsonrpc" => "2.0",
        "id" => "after-ping",
        "method" => "tools/call",
        "params" => {
          "_meta" => {
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => {},
            "io.modelcontextprotocol/clientInfo" => {
              "name" => "after-fixture",
              "version" => "1"
            }
          },
          "name" => "ping",
          "arguments" => {}
        }
      }
    }
  ]
)


def read_request(socket)
  request_line = socket.gets("\n")
  raise "missing HTTP request line" if request_line.nil?

  method, target, version = request_line.strip.split(" ", 3)
  raise "malformed HTTP request line" if [method, target, version].any?(&:nil?)

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

def validate_common(headers)
  raise "bearer credential changed" unless
    one_header(headers, "Authorization") == "Bearer test-secret"
  raise "client name changed" unless
    one_header(headers, "X-Tunnel-Client-Name") == "sonbal"
  raise "client version changed" unless
    one_header(headers, "X-Tunnel-Client-Version") == "1"
end

def write_response(socket, code, reason, body = "")
  headers =
    "HTTP/1.1 #{code} #{reason}\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Connection: close\r\n"
  headers += "Content-Type: application/json\r\n" unless body.empty?
  socket.write(headers + "\r\n" + body)
end

def wait_for_peer_close(socket, label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0

  loop do
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      raise "deadline shutdown did not cancel held #{label}"
    end

    ready = IO.select([socket], nil, nil, 0.1)
    next if ready.nil?

    peek = socket.recv_nonblock(
      1,
      Socket::MSG_PEEK,
      exception: false
    )

    return true if peek.nil? || peek == ""
    next if peek == :wait_readable

    raise "unexpected bytes on held #{label}"
  end
end


def run_fixture(executable, hold_response_post:)
  server = TCPServer.new("127.0.0.1", 0)
  base_url = "http://127.0.0.1:#{server.addr[1]}"
  errors = Queue.new
  poll_count = 0
  held_poll_cancelled = false
  held_post_cancelled = false

  server_thread = Thread.new do
    begin
      loop do
        socket = server.accept
        begin
          method, target, headers, body = read_request(socket)
          validate_common(headers)

          if method == "POST"
            expected = "/v1/tunnels/deadline-test/response"
            raise "queue response target changed: #{target}" unless target == expected
            payload = JSON.parse(body)
            request_id = payload["request_id"]
            expected_shard =
              request_id == "req_queue" ? "shard-queue" : "shard-after"
            expected_jsonrpc_id =
              request_id == "req_queue" ? "queue-ping" : "after-ping"

            unless ["req_queue", "req_after"].include?(request_id) &&
                   one_header(headers, "X-Tunnel-Shard-Token") == expected_shard &&
                   payload["resp_code"] == 200 &&
                   payload["resp_type"] == "jsonrpc_response" &&
                   payload["resp_json"].is_a?(Hash) &&
                   payload["resp_json"]["id"] == expected_jsonrpc_id
              raise "response envelope changed"
            end

            if hold_response_post && request_id == "req_queue"
              held_post_cancelled =
                wait_for_peer_close(socket, "response POST")
              break
            end

            write_response(socket, 200, "OK", '{"status":"ok"}')
            next
          end

          unless method == "GET"
            raise "deadline transport unexpectedly sent #{method}"
          end

          expected =
            "/v1/tunnels/deadline-test/poll?limit=20&timeout_ms=1000"
          raise "deadline poll target changed: #{target}" unless target == expected
          raise "deadline poll unexpectedly had a body" unless body.empty?

          poll_count += 1

          if poll_count == 1
            write_response(socket, 200, "OK", COMMAND_BODY)
          elsif hold_response_post
            raise "blocking response fixture unexpectedly polled again"
          else
            held_poll_cancelled =
              wait_for_peer_close(socket, "deadline poll")
            break
          end
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue StandardError => error
      errors << error
    end
  end

  stdout = nil
  stderr = nil
  status = nil

  begin
    Timeout.timeout(15) do
      stdout, stderr, status = Open3.capture3(
        {
          "HTTP_PROXY" => "http://127.0.0.1:1",
          "http_proxy" => "http://127.0.0.1:1",
          "NO_PROXY" => "",
          "no_proxy" => ""
        },
        executable,
        base_url
      )
    end
  ensure
    server.close unless server.closed?
  end

  unless server_thread.join(5)
    abort "OpenAI deadline mock server did not stop"
  end

  unless status&.success?
    warn stdout
    warn stderr
    abort "OpenAI inflight deadline transport fixture failed"
  end

  unless stdout.include?("[PASS] OpenAI connector inflight deadline transport")
    abort "OpenAI inflight deadline success marker missing"
  end

  unless errors.empty?
    error = errors.pop
    abort "OpenAI deadline mock-server assertion failed: #{error.message}"
  end

  if hold_response_post
    abort "HTTP worker never entered held response POST" unless
      held_post_cancelled
  else
    abort "HTTP worker never entered held follow-up poll" if poll_count < 2
    abort "deadline shutdown did not close held poll" unless
      held_poll_cancelled
  end
end

run_fixture(executable, hold_response_post: false)
run_fixture(executable, hold_response_post: true)

puts "[PASS] OpenAI connector bounded queue/deadline integration"
