# =============================================================================
# sonbal_connector_openai_http_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "open3"
require "socket"
require "time"
require "timeout"

executable = ARGV.fetch(0) do
  abort "usage: #{$PROGRAM_NAME} HTTP_TEST_EXECUTABLE"
end
abort "usage: #{$PROGRAM_NAME} HTTP_TEST_EXECUTABLE" unless ARGV.length == 1

EXPECTED_REQUESTS = 7
POLL_TARGET =
  "/v1/tunnels/tunnel%2Fopaque/poll?limit=7&timeout_ms=30000"
RESPONSE_TARGET = "/v1/tunnels/tunnel%2Fopaque/response"
WIRE_VERSION = "2026-08-25"

RESPONSE_JSON =
  '{"request_id":"req_1","channel":"main",' \
  '"resp_json":{"jsonrpc":"2.0","id":1,"result":{"ok":true}},' \
  '"resp_code":200,"resp_type":"jsonrpc_response"}'

def read_request(socket)
  request_line = socket.gets("\n")
  raise "missing HTTP request line" if request_line.nil?

  method, target, version = request_line.strip.split(" ", 3)
  raise "malformed HTTP request line" if method.nil? || target.nil? || version.nil?

  headers = Hash.new { |hash, key| hash[key] = [] }
  loop do
    line = socket.gets("\n")
    raise "truncated HTTP request headers" if line.nil?
    break if line == "\r\n" || line == "\n"

    name, value = line.split(":", 2)
    raise "malformed HTTP header" if value.nil?

    headers[name.downcase] << value.strip
  end

  content_length =
    Integer(headers.fetch("content-length", ["0"]).fetch(0), 10)
  body = content_length.zero? ? "" : socket.read(content_length)
  raise "truncated HTTP request body" if body.nil? ||
    body.bytesize != content_length

  [method, target, headers, body]
end

def one_header(headers, name)
  values = headers[name.downcase]
  raise "missing #{name}" if values.nil? || values.empty?
  raise "duplicate #{name}" unless values.length == 1

  values.fetch(0)
end

def validate_common(headers)
  raise "bearer credential changed" unless
    one_header(headers, "Authorization") == "Bearer test-secret"
  raise "Accept header missing JSON" unless
    one_header(headers, "Accept").split(",").map(&:strip).include?(
      "application/json"
    )
  raise "client name changed" unless
    one_header(headers, "X-Tunnel-Client-Name") == "sonbal-test"
  raise "client version changed" unless
    one_header(headers, "X-Tunnel-Client-Version") == "1"
  raise "wire protocol version changed" unless
    one_header(
      headers, "X-Tunnel-Client-Wire-Protocol-Version"
    ) == WIRE_VERSION

  if headers.key?("x-tunnel-client-capabilities")
    raise "unimplemented tunnel capability was advertised"
  end
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
handlers = []
mutex = Mutex.new
accepted = 0

accept_thread = Thread.new do
  loop do
    socket = server.accept
    index = mutex.synchronize do
      accepted += 1
      accepted
    end

    handlers << Thread.new(socket, index) do |connection, request_index|
      begin
        method, target, headers, body = read_request(connection)
        validate_common(headers)

        case request_index
        when 1
          raise "first poll method changed" unless method == "GET"
          raise "first poll target changed: #{target}" unless
            target == POLL_TARGET
          raise "GET poll unexpectedly had a body" unless body.empty?
          write_response(connection, 200, "OK", '{"commands":[]}')
        when 2
          raise "429 poll target changed: #{target}" unless
            method == "GET" && target == POLL_TARGET
          write_response(
            connection,
            429,
            "Too Many Requests",
            '{"error":"rate-limit"}',
            "Retry-After" => "2"
          )
        when 3
          raise "503 poll target changed: #{target}" unless
            method == "GET" && target == POLL_TARGET
          write_response(
            connection,
            503,
            "Service Unavailable",
            '{"error":"unavailable"}',
            "Retry-After" => (Time.now.utc + 3).httpdate
          )
        when 4
          raise "empty poll method changed" unless method == "GET"
          raise "empty poll target changed: #{target}" unless
            target == POLL_TARGET
          write_response(connection, 204, "No Content")
        when 5
          raise "body-limit poll target changed: #{target}" unless
            method == "GET" && target == POLL_TARGET
          write_response(
            connection,
            200,
            "OK",
            '{"commands":[],"padding":"' + ("x" * 128) + '"}'
          )
        when 6
          raise "cancel poll target changed: #{target}" unless
            method == "GET" && target == POLL_TARGET
          sleep 2
          begin
            write_response(connection, 200, "OK", '{"commands":[]}')
          rescue Errno::EPIPE, Errno::ECONNRESET, IOError
            # Expected after the client-side progress callback cancels.
          end
        when 7
          raise "response method changed" unless method == "POST"
          raise "response target changed: #{target}" unless
            target == RESPONSE_TARGET
          raise "response shard token changed" unless
            one_header(
              headers, "X-Tunnel-Shard-Token"
            ) == "opaque-shard-token"
          raise "response Content-Type changed" unless
            one_header(
              headers, "Content-Type"
            ).downcase.start_with?("application/json")
          raise "response JSON body changed" unless body == RESPONSE_JSON
          write_response(connection, 200, "OK", '{"status":"ok"}')
        else
          raise "unexpected extra HTTP request #{request_index}"
        end
      rescue StandardError => error
        errors << error
      ensure
        connection.close unless connection.closed?
      end
    end

    break if index >= EXPECTED_REQUESTS
  end
rescue IOError, Errno::EBADF
  # The parent closes the listener during cleanup.
end

stdout = nil
stderr = nil
status = nil
begin
  Timeout.timeout(20) do
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

accept_thread.join(5)
handlers.each { |thread| thread.join(5) }

unless status&.success?
  warn stdout
  warn stderr
  abort "OpenAI HTTP primitive executable failed"
end

unless stdout.include?("[PASS] OpenAI connector bounded HTTP primitive")
  abort "OpenAI HTTP primitive success marker missing"
end

unless accepted == EXPECTED_REQUESTS
  abort "expected #{EXPECTED_REQUESTS} HTTP requests, observed #{accepted}"
end

unless errors.empty?
  error = errors.pop
  abort "OpenAI HTTP mock-server assertion failed: #{error.message}"
end

puts "[PASS] OpenAI connector HTTP wire integration"
