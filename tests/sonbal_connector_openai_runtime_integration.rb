# =============================================================================
# sonbal_connector_openai_runtime_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "socket"
require "tempfile"
require "timeout"

fixture = File.expand_path(
  ARGV.fetch(0) do
    abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN"
  end
)
plugin = File.expand_path(
  ARGV.fetch(1) do
    abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN"
  end
)
abort "usage: #{$PROGRAM_NAME} FIXTURE PLUGIN" unless ARGV.length == 2

MCP_META = {
  "_meta" => {
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => {},
    "io.modelcontextprotocol/clientInfo" => {
      "name" => "openai-runtime-fixture",
      "version" => "1"
    }
  }
}.freeze

PING_COMMANDS = (1..20).map do |index|
  {
    "request_id" => "req_ping_#{index}",
    "shard_token" => "shard-ping-#{index}",
    "command_type" => "jsonrpc",
    "channel" => "main",
    "created_at" => "2026-09-30T00:00:00Z",
    "jsonrpc" => {
      "jsonrpc" => "2.0",
      "id" => "connector-ping-#{index}",
      "method" => "tools/call",
      "params" => {
        "_meta" => MCP_META["_meta"],
        "name" => "ping",
        "arguments" => {}
      }
    }
  }
end.freeze

EXPIRED_COMMAND = {
  "request_id" => "req_expired",
  "shard_token" => "shard-expired",
  "command_type" => "jsonrpc",
  "channel" => "main",
  "created_at" => "2026-09-30T00:00:00Z",
  "response_timeout" => "0s",
  "jsonrpc" => {
    "jsonrpc" => "2.0",
    "id" => "expired-ping",
    "method" => "tools/call",
    "params" => {
      "_meta" => MCP_META["_meta"],
      "name" => "ping",
      "arguments" => {}
    }
  }
}.freeze

NOTIFICATION_COMMAND = {
  "request_id" => "req_notification",
  "shard_token" => "shard-notification",
  "command_type" => "jsonrpc",
  "channel" => "main",
  "created_at" => "2026-09-30T00:00:00Z",
  "jsonrpc" => {
    "jsonrpc" => "2.0",
    "method" => "notifications/progress",
    "params" => {}
  }
}.freeze

PING_POLL_BODY =
  JSON.generate(
    "commands" => [EXPIRED_COMMAND] + PING_COMMANDS + [NOTIFICATION_COMMAND]
  )

SESSION_POLL_BODY = JSON.generate(
  "commands" => [
    {
      "request_id" => "req_session",
      "shard_token" => "shard-session",
      "command_type" => "session_termination",
      "channel" => "main",
      "created_at" => "2026-09-30T00:00:00Z"
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
  raise "wire version changed" unless
    one_header(
      headers,
      "X-Tunnel-Client-Wire-Protocol-Version"
    ) == "2026-08-25"
end

def write_response(socket, code, reason, body = "", extra_headers = {})
  headers =
    "HTTP/1.1 #{code} #{reason}\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Connection: close\r\n"
  headers += "Content-Type: application/json\r\n" unless body.empty?
  extra_headers.each do |name, value|
    headers += "#{name}: #{value}\r\n"
  end
  socket.write(headers + "\r\n" + body)
end

server = TCPServer.new("127.0.0.1", 0)
base_url = "http://127.0.0.1:#{server.addr[1]}"
errors = Queue.new
posts = {}
post_attempts = Hash.new(0)
poll_count = 0
first_poll_time = nil
second_poll_time = nil
first_ping_retry_body = nil
first_ping_retry_shard = nil
first_ping_retry_time = nil
second_ping_retry_time = nil
held_poll_cancelled = false

server_thread = Thread.new do
  begin
    loop do
      socket = server.accept
      begin
        method, target, headers, body = read_request(socket)
        validate_common(headers)

        if method == "GET"
          poll_count += 1
          expected =
            "/v1/tunnels/runtime-test/poll?limit=18&timeout_ms=1000"
          raise "poll target changed: #{target}" unless target == expected

          if poll_count == 1
            first_poll_time =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            write_response(
              socket,
              503,
              "Service Unavailable",
              '{"error":"retry-poll"}',
              "Retry-After" => "0"
            )
          elsif poll_count == 2
            second_poll_time =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            write_response(socket, 200, "OK", PING_POLL_BODY)
          elsif poll_count == 3
            write_response(socket, 200, "OK", SESSION_POLL_BODY)
          else
            deadline =
              Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0

            loop do
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                raise "held long poll was not cancelled within five seconds"
              end

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
                raise "unexpected bytes arrived on held poll connection: #{peek.bytes.inspect}"
              end
            end
            break
          end
        elsif method == "POST"
          expected = "/v1/tunnels/runtime-test/response"
          raise "response target changed: #{target}" unless target == expected
          payload = JSON.parse(body)
          request_id = payload.fetch("request_id")
          shard = one_header(headers, "X-Tunnel-Shard-Token")
          post_attempts[request_id] += 1

          if request_id == "req_ping_1" &&
             post_attempts[request_id] == 1
            first_ping_retry_body = body.dup
            first_ping_retry_shard = shard.dup
            first_ping_retry_time =
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            write_response(
              socket,
              503,
              "Service Unavailable",
              '{"error":"retry-post"}',
              "Retry-After" => "0"
            )
          else
            if request_id == "req_ping_1"
              second_ping_retry_time =
                Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise "retry POST body changed" unless
                body == first_ping_retry_body
              raise "retry POST shard changed" unless
                shard == first_ping_retry_shard
            end

            posts[request_id] = {
              "payload" => payload,
              "shard" => shard
            }
            write_response(socket, 200, "OK", '{"status":"ok"}')
          end
        else
          raise "unexpected HTTP method #{method}"
        end
      ensure
        socket.close unless socket.closed?
      end
    end
  rescue StandardError => error
    errors << error
  end
end

config = Tempfile.new("sonbal-openai-runtime-config")
credential = Tempfile.new("sonbal-openai-runtime-credential")

begin
  config.write(
    JSON.generate(
      "tunnel_id" => "runtime-test",
      "poll_limit" => 18,
      "poll_timeout_ms" => 1000
    )
  )
  config.flush

  credential.write("test-secret\n")
  credential.flush

  stdout = nil
  stderr = nil
  status = nil

  Timeout.timeout(20) do
    stdout, stderr, status = Open3.capture3(
      {
        "SONBAL_OPENAI_TEST_BASE_URL" => base_url,
        "HTTP_PROXY" => "http://127.0.0.1:1",
        "http_proxy" => "http://127.0.0.1:1",
        "NO_PROXY" => "",
        "no_proxy" => ""
      },
      fixture,
      plugin,
      config.path,
      credential.path
    )
  end

  unless status&.success?
    warn stdout
    warn stderr
    abort "OpenAI runtime fixture failed"
  end

  unless stdout.include?("[PASS] OpenAI connector runtime lifecycle")
    abort "OpenAI runtime success marker missing"
  end
ensure
  config.close!
  credential.close!
  server.close unless server.closed?
end

server_thread.join(5)

unless errors.empty?
  error = errors.pop
  abort "OpenAI runtime mock-server assertion failed: #{error.message}"
end

PING_COMMANDS.each_with_index do |command, zero_index|
  index = zero_index + 1
  response = posts["req_ping_#{index}"]
  abort "JSON-RPC response POST #{index} missing" if response.nil?

  unless response["shard"] == "shard-ping-#{index}"
    abort "JSON-RPC shard token #{index} changed"
  end

  payload = response["payload"]
  unless payload["channel"] == "main" &&
         payload["resp_code"] == 200 &&
         payload["resp_type"] == "jsonrpc_response" &&
         payload["resp_json"].is_a?(Hash) &&
         payload["resp_json"]["jsonrpc"] == "2.0" &&
         payload["resp_json"]["id"] == "connector-ping-#{index}"
    abort "JSON-RPC response envelope #{index} changed"
  end
end

abort "immediately expired command produced a response" if
  posts.key?("req_expired")

notification = posts["req_notification"]
abort "JSON-RPC notification acknowledgement missing" if notification.nil?

unless notification["shard"] == "shard-notification"
  abort "notification shard token changed"
end

notification_payload = notification["payload"]
unless notification_payload["channel"] == "main" &&
       notification_payload["resp_code"] == 204 &&
       notification_payload["resp_type"] == "notify_ack" &&
       !notification_payload.key?("resp_json")
  abort "notification acknowledgement envelope changed"
end

session = posts["req_session"]
abort "session termination acknowledgement missing" if session.nil?

unless session["shard"] == "shard-session"
  abort "session shard token changed"
end

session_payload = session["payload"]
unless session_payload["channel"] == "main" &&
       session_payload["resp_code"] == 204 &&
       session_payload["resp_type"] == "session_termination_response" &&
       !session_payload.key?("resp_json")
  abort "session termination response envelope changed"
end

abort "runtime worker never retried the transient poll" if poll_count < 2
abort "runtime worker never entered the session poll" if poll_count < 3
abort "runtime worker never entered a held shutdown poll" if poll_count < 4
abort "held long poll was not cancelled" unless held_poll_cancelled

if first_poll_time.nil? || second_poll_time.nil?
  abort "poll retry timing was not observed"
end

poll_retry_delay = second_poll_time - first_poll_time
unless poll_retry_delay >= 0.08 && poll_retry_delay <= 2.0
  abort "poll retry backoff out of bounds: #{poll_retry_delay}"
end

unless post_attempts["req_ping_1"] == 2
  abort "terminal response was not retried exactly once"
end

PING_COMMANDS.drop(1).each_with_index do |_command, zero_index|
  request_id = "req_ping_#{zero_index + 2}"
  unless post_attempts[request_id] == 1
    abort "unexpected retry count for #{request_id}: #{post_attempts[request_id]}"
  end
end

unless post_attempts["req_notification"] == 1
  abort "unexpected notification acknowledgement retry count"
end

unless post_attempts["req_session"] == 1
  abort "unexpected session acknowledgement retry count"
end

if first_ping_retry_time.nil? || second_ping_retry_time.nil?
  abort "terminal POST retry timing was not observed"
end

post_retry_delay = second_ping_retry_time - first_ping_retry_time
unless post_retry_delay >= 0.08 && post_retry_delay <= 2.0
  abort "terminal POST retry backoff out of bounds: #{post_retry_delay}"
end

puts "[PASS] OpenAI connector runtime wire lifecycle"
