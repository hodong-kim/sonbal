# =============================================================================
# sonbal_connector_service_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

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

server = TCPServer.new("127.0.0.1", 0)
base_url = "http://127.0.0.1:#{server.addr[1]}"
errors = Queue.new
held_poll_cancelled = false

server_thread = Thread.new do
  begin
    socket = server.accept
    begin
      method, target, headers, _body = read_request(socket)
      raise "unexpected method #{method}" unless method == "GET"
      expected = "/v1/tunnels/service-test/poll?limit=7&timeout_ms=30000"
      raise "unexpected poll target #{target}" unless target == expected
      raise "bearer credential changed" unless
        one_header(headers, "Authorization") == "Bearer service-test-secret"
      raise "client name changed" unless
        one_header(headers, "X-Tunnel-Client-Name") == "sonbal"
      raise "client version changed" unless
        one_header(headers, "X-Tunnel-Client-Version") == "1"
      raise "wire version changed" unless
        one_header(
          headers,
          "X-Tunnel-Client-Wire-Protocol-Version"
        ) == "2026-08-25"

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      loop do
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "held connector-service poll was not cancelled"
        end

        readable = IO.select([socket], nil, nil, 0.1)
        next if readable.nil?

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
          raise "unexpected bytes on held poll: #{peek.bytes.inspect}"
        end
      end
    ensure
      socket.close unless socket.closed?
    end
  rescue StandardError => error
    errors << error
  end
end

config = Tempfile.new("sonbal-connector-service-config")
credential = Tempfile.new("sonbal-connector-service-credential")

begin
  config.write(
    JSON.generate(
      "tunnel_id" => "service-test",
      "poll_limit" => 7,
      "poll_timeout_ms" => 30_000
    )
  )
  config.flush

  credential.write("service-test-secret\n")
  credential.flush

  stdout = ""
  stderr = ""
  status = nil

  Timeout.timeout(15) do
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
    abort "connector service fixture failed"
  end

  unless stdout.include?("[PASS] connector service bounded lifecycle")
    abort "connector service success marker missing"
  end

  if stdout.include?("service-test-secret") ||
     stderr.include?("service-test-secret")
    abort "connector service diagnostics exposed credential"
  end
ensure
  config.close!
  credential.close!
  server.close unless server.closed?
end

server_thread.join(5)
abort "connector-service mock server did not terminate" if server_thread.alive?

unless errors.empty?
  error = errors.pop
  abort "connector-service mock server assertion failed: #{error.message}"
end

abort "connector service did not cancel held provider poll" unless
  held_poll_cancelled

puts "[PASS] connector service startup, signal, and bounded shutdown"
