#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_chatgpt_job_probe.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "json"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"
require "time"

PROTOCOL_VERSION = "2026-07-28"
MAX_HTTP_HEADER_BYTES = 32_768
MAX_REQUEST_BYTES = 1_048_576
MAX_RECORD_BYTES = 16_384
MAX_JOBS = 32
JOB_TTL_SECONDS = 600

class ProbeFailure < StandardError; end

def assert(condition, message)
  raise ProbeFailure, message unless condition
end

def compact_json(value)
  JSON.generate(value)
end

def result_envelope(id, result)
  compact_json("jsonrpc" => "2.0", "id" => id, "result" => result)
end

def error_envelope(id, code, message)
  compact_json(
    "jsonrpc" => "2.0",
    "id" => id,
    "error" => {"code" => code, "message" => message}
  )
end

def tool_result(id, payload, is_error: false)
  result_envelope(
    id,
    "resultType" => "complete",
    "content" => [
      {"type" => "text", "text" => payload.fetch("status")}
    ],
    "structuredContent" => payload,
    "isError" => is_error,
    "_meta" => {}
  )
end

class JobProbeServer
  def initialize(socket_path: nil, listen_host: nil, listen_port: nil, record_path:)
    if socket_path.nil? == listen_host.nil?
      raise ArgumentError, "select exactly one probe listener"
    end
    if !listen_host.nil? && listen_host != "127.0.0.1"
      raise ArgumentError, "TCP probe listener must use 127.0.0.1"
    end

    @socket_path = socket_path.nil? ? nil : File.expand_path(socket_path)
    @listen_host = listen_host
    @listen_port = listen_port
    @record_path = File.expand_path(record_path)
    @jobs = {}
    @listener = nil
    @bound_port = nil
    @stopping = false
  end

  attr_reader :socket_path, :record_path, :bound_port

  def run
    FileUtils.mkdir_p(File.dirname(@record_path))
    if @socket_path
      FileUtils.mkdir_p(File.dirname(@socket_path))
      FileUtils.rm_f(@socket_path)
      @listener = UNIXServer.new(@socket_path)
      File.chmod(0o600, @socket_path)
    else
      @listener = TCPServer.new(@listen_host, @listen_port)
      @bound_port = @listener.addr[1]
    end

    until @stopping
      begin
        ready = IO.select([@listener], nil, nil, 0.1)
        next if ready.nil?

        client = @listener.accept_nonblock(exception: false)
        next if client == :wait_readable
      rescue Errno::EINTR
        next
      rescue IOError, Errno::EBADF
        break if @stopping
        raise
      end

      begin
        handle_connection(client)
      rescue StandardError => error
        warn "[probe] request failure: #{error.class}: #{error.message}"
      ensure
        client.close unless client.closed?
      end
    end
  ensure
    @listener&.close unless @listener&.closed?
    FileUtils.rm_f(@socket_path) unless @socket_path.nil?
  end

  def stop
    @stopping = true
  end

  private

  def handle_connection(client)
    method, path, headers, body = read_request(client)
    unless method == "POST" && path == "/mcp"
      write_http(client, 404, compact_json("error" => "not found"))
      return
    end

    content_type = headers.fetch("content-type", "")
    unless content_type.downcase.start_with?("application/json")
      write_http(client, 415, compact_json("error" => "json required"))
      return
    end

    message = JSON.parse(body)
    response = dispatch(message)
    write_http(client, 200, response)
  rescue JSON::ParserError
    write_http(client, 400, error_envelope(nil, -32_700, "parse error"))
  rescue ProbeFailure => error
    write_http(client, 400, error_envelope(nil, -32_600, error.message))
  end

  def read_request(client)
    input = +""
    delimiter = nil

    loop do
      delimiter = input.index("\r\n\r\n")
      break unless delimiter.nil?
      raise ProbeFailure, "HTTP headers exceed bound" if
        input.bytesize >= MAX_HTTP_HEADER_BYTES

      input << client.readpartial(4096)
    end

    header_text = input.byteslice(0, delimiter)
    remainder = input.byteslice(delimiter + 4, input.bytesize) || ""
    lines = header_text.split("\r\n")
    request_line = lines.shift.to_s.split(" ")
    raise ProbeFailure, "invalid request line" unless request_line.length == 3

    headers = {}
    lines.each do |line|
      name, value = line.split(":", 2)
      raise ProbeFailure, "invalid header" if name.nil? || value.nil?
      headers[name.downcase] = value.strip
    end

    length_text = headers["content-length"]
    if length_text.nil?
      raise ProbeFailure, "content length required" unless
        %w[GET HEAD].include?(request_line[0])
      length = 0
    else
      raise ProbeFailure, "invalid content length" unless length_text.match?(/\A\d+\z/)
      length = Integer(length_text, 10)
    end
    raise ProbeFailure, "request body exceeds bound" if length > MAX_REQUEST_BYTES

    body = +remainder
    while body.bytesize < length
      body << client.readpartial([4096, length - body.bytesize].min)
    end
    raise ProbeFailure, "request body length mismatch" unless body.bytesize == length

    [request_line[0], request_line[1], headers, body]
  rescue EOFError
    raise ProbeFailure, "unexpected request EOF"
  end

  def write_http(client, status, body)
    reason = status == 200 ? "OK" : "Error"
    headers = [
      "HTTP/1.1 #{status} #{reason}",
      "Content-Type: application/json",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      ""
    ].join("\r\n")
    client.write("#{headers}\r\n#{body}")
  end

  def dispatch(message)
    raise ProbeFailure, "request must be an object" unless message.is_a?(Hash)

    id = message["id"]
    method = message["method"]
    params = message.fetch("params", {})
    raise ProbeFailure, "params must be an object" unless params.is_a?(Hash)

    cleanup_expired_jobs

    case method
    when "server/discover"
      record_discover(params.fetch("_meta", {}))
      discover_response(id)
    when "tools/list"
      tools_list_response(id)
    when "tools/call"
      tools_call_response(id, params)
    else
      error_envelope(id, -32_601, "method not found")
    end
  end

  def discover_response(id)
    result_envelope(
      id,
      "resultType" => "complete",
      "supportedVersions" => [PROTOCOL_VERSION],
      "capabilities" => {"tools" => {}},
      "_meta" => {
        "io.modelcontextprotocol/serverInfo" => {
          "name" => "sonbal-chatgpt-job-probe",
          "version" => "1"
        }
      },
      "ttlMs" => 0,
      "cacheScope" => "private"
    )
  end

  def tools_list_response(id)
    result_envelope(
      id,
      "resultType" => "complete",
      "tools" => [start_descriptor, poll_descriptor, cancel_descriptor]
    )
  end

  def start_descriptor
    {
      "name" => "start_process",
      "description" =>
        "TEST ONLY. Starts a deterministic fake long-running process job. " \
        "No OS process is executed. Preserve the returned job_id and cursor.",
      "inputSchema" => process_input_schema,
      "annotations" => {
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => false
      }
    }
  end

  def poll_descriptor
    {
      "name" => "poll_process",
      "description" =>
        "TEST ONLY. Reads one deterministic incremental result for a fake " \
        "job. Pass the exact job_id and cursor returned by the prior call.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "job_id" => {"type" => "string", "minLength" => 1, "maxLength" => 96},
          "cursor" => {"type" => "string", "minLength" => 1, "maxLength" => 128}
        },
        "required" => ["job_id", "cursor"],
        "additionalProperties" => false
      },
      "annotations" => {
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  def cancel_descriptor
    {
      "name" => "cancel_process",
      "description" =>
        "TEST ONLY. Marks a deterministic fake job cancelled. No OS process " \
        "is signalled.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "job_id" => {"type" => "string", "minLength" => 1, "maxLength" => 96}
        },
        "required" => ["job_id"],
        "additionalProperties" => false
      },
      "annotations" => {
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  def process_input_schema
    {
      "type" => "object",
      "properties" => {
        "argv" => {
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 65,
          "items" => {"type" => "string", "maxLength" => 32_768}
        },
        "resolution" => {
          "type" => "string",
          "enum" => ["exact_path", "search_path"]
        },
        "cwd" => {"type" => "string", "minLength" => 1, "maxLength" => 4096},
        "timeout_ms" => {
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 180_000
        }
      },
      "required" => ["argv", "resolution", "cwd", "timeout_ms"],
      "additionalProperties" => false
    }
  end

  def tools_call_response(id, params)
    name = params["name"]
    arguments = params.fetch("arguments", {})
    unless name.is_a?(String) && arguments.is_a?(Hash)
      return error_envelope(id, -32_602, "invalid params")
    end

    case name
    when "start_process"
      start_process(id, arguments)
    when "poll_process"
      poll_process(id, arguments)
    when "cancel_process"
      cancel_process(id, arguments)
    else
      error_envelope(id, -32_602, "unknown tool")
    end
  end

  def start_process(id, arguments)
    unless valid_process_arguments?(arguments)
      return error_envelope(id, -32_602, "invalid process arguments")
    end
    if @jobs.length >= MAX_JOBS
      return tool_result(id, {"status" => "execution_busy"}, is_error: true)
    end

    job_id = "probe-#{SecureRandom.hex(16)}"
    job = {
      "id" => job_id,
      "cancelled" => false,
      "createdAt" => Process.clock_gettime(Process::CLOCK_MONOTONIC)
    }
    @jobs[job_id] = job
    cursor = cursor_for(job_id, 0)
    record_tool_call("start_process", job_id: job_id, cursor: cursor)
    tool_result(
      id,
      {"status" => "running", "job_id" => job_id, "cursor" => cursor}
    )
  end

  def poll_process(id, arguments)
    return error_envelope(id, -32_602, "invalid poll arguments") unless
      exact_keys?(arguments, %w[job_id cursor]) &&
      arguments["job_id"].is_a?(String) && arguments["cursor"].is_a?(String)

    job_id = arguments["job_id"]
    job = @jobs[job_id]
    return tool_result(id, {"status" => "not_found"}, is_error: true) if job.nil?

    index = cursor_index(job_id, arguments["cursor"])
    return error_envelope(id, -32_602, "invalid cursor") if index.nil?

    record_tool_call("poll_process", job_id: job_id, cursor: arguments["cursor"])
    if job["cancelled"]
      return tool_result(
        id,
        {
          "status" => "cancelled",
          "job_id" => job_id,
          "stdout" => "",
          "stderr" => "",
          "next_cursor" => arguments["cursor"]
        }
      )
    end

    payload = poll_payload(job_id, index)
    tool_result(id, payload)
  end

  def cancel_process(id, arguments)
    return error_envelope(id, -32_602, "invalid cancel arguments") unless
      exact_keys?(arguments, ["job_id"]) && arguments["job_id"].is_a?(String)

    job_id = arguments["job_id"]
    job = @jobs[job_id]
    return tool_result(id, {"status" => "not_found"}, is_error: true) if job.nil?

    job["cancelled"] = true
    record_tool_call("cancel_process", job_id: job_id)
    tool_result(id, {"status" => "cancelled", "job_id" => job_id})
  end

  def valid_process_arguments?(arguments)
    return false unless exact_keys?(arguments, %w[argv resolution cwd timeout_ms])

    argv = arguments["argv"]
    resolution = arguments["resolution"]
    cwd = arguments["cwd"]
    timeout = arguments["timeout_ms"]
    argv.is_a?(Array) && argv.length.between?(1, 65) &&
      argv.all? { |item| item.is_a?(String) && item.bytesize <= 32_768 } &&
      argv.sum(&:bytesize) <= 32_768 && !argv.first.empty? &&
      %w[exact_path search_path].include?(resolution) &&
      cwd.is_a?(String) && cwd.start_with?("/") && cwd.bytesize <= 4096 &&
      timeout.is_a?(Integer) && timeout.between?(1, 180_000)
  end

  def exact_keys?(value, expected)
    value.keys.sort == expected.sort
  end

  def poll_payload(job_id, index)
    case index
    when 0
      {
        "status" => "running",
        "job_id" => job_id,
        "stdout" => "probe-started\n",
        "stderr" => "",
        "next_cursor" => cursor_for(job_id, 1)
      }
    when 1
      {
        "status" => "running",
        "job_id" => job_id,
        "stdout" => "",
        "stderr" => "probe-progress\n",
        "next_cursor" => cursor_for(job_id, 2)
      }
    when 2
      {
        "status" => "exited",
        "job_id" => job_id,
        "stdout" => "probe-complete\n",
        "stderr" => "",
        "next_cursor" => cursor_for(job_id, 3),
        "exit_code" => 0
      }
    when 3
      {
        "status" => "exited",
        "job_id" => job_id,
        "stdout" => "",
        "stderr" => "",
        "next_cursor" => cursor_for(job_id, 3),
        "exit_code" => 0
      }
    else
      raise ProbeFailure, "cursor outside retained probe output"
    end
  end

  def cursor_for(job_id, index)
    "#{job_id}:#{index}"
  end

  def cursor_index(job_id, cursor)
    prefix = "#{job_id}:"
    return nil unless cursor.start_with?(prefix)

    text = cursor.delete_prefix(prefix)
    return nil unless text.match?(/\A[0-3]\z/)

    Integer(text, 10)
  end

  def cleanup_expired_jobs
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @jobs.delete_if { |_id, job| now - job["createdAt"] > JOB_TTL_SECONDS }
  end

  def record_discover(meta)
    meta = {} unless meta.is_a?(Hash)
    info = meta["io.modelcontextprotocol/clientInfo"]
    info = {} unless info.is_a?(Hash)
    event = {
      "event" => "server_discover",
      "observedAt" => Time.now.utc.iso8601,
      "protocolVersion" => meta["io.modelcontextprotocol/protocolVersion"],
      "clientCapabilities" =>
        meta["io.modelcontextprotocol/clientCapabilities"],
      "clientInfo" => {
        "name" => info["name"],
        "version" => info["version"]
      }
    }
    append_record(event)
  end

  def record_tool_call(name, job_id: nil, cursor: nil)
    event = {
      "event" => "tool_call",
      "observedAt" => Time.now.utc.iso8601,
      "name" => name
    }
    event["job_id"] = job_id unless job_id.nil?
    event["cursor"] = cursor unless cursor.nil?
    append_record(event)
  end

  def append_record(event)
    line = compact_json(event)
    raise ProbeFailure, "sanitized probe record exceeds bound" if
      line.bytesize > MAX_RECORD_BYTES

    File.open(@record_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
      File.chmod(0o600, @record_path)
      file.write(line)
      file.write("\n")
      file.flush
    end
  end
end

def unix_post(socket_path, message)
  body = compact_json(message)
  socket = UNIXSocket.new(socket_path)
  request = [
    "POST /mcp HTTP/1.1",
    "Host: localhost",
    "Content-Type: application/json",
    "Accept: application/json, text/event-stream",
    "Content-Length: #{body.bytesize}",
    "MCP-Protocol-Version: #{PROTOCOL_VERSION}",
    "Connection: close",
    "",
    body
  ].join("\r\n")
  socket.write(request)
  response = socket.read
  socket.close

  head, response_body = response.split("\r\n\r\n", 2)
  raise ProbeFailure, "probe returned malformed HTTP" if response_body.nil?
  status = head.lines.first.to_s.split[1]
  raise ProbeFailure, "probe HTTP status #{status}" unless status == "200"

  JSON.parse(response_body)
end

def tcp_post(host, port, message)
  body = compact_json(message)
  socket = TCPSocket.new(host, port)
  request = [
    "POST /mcp HTTP/1.1",
    "Host: localhost",
    "Content-Type: application/json",
    "Accept: application/json, text/event-stream",
    "Content-Length: #{body.bytesize}",
    "MCP-Protocol-Version: #{PROTOCOL_VERSION}",
    "Connection: close",
    "",
    body
  ].join("\r\n")
  socket.write(request)
  response = socket.read
  socket.close

  head, response_body = response.split("\r\n\r\n", 2)
  raise ProbeFailure, "probe returned malformed HTTP" if response_body.nil?
  status = head.lines.first.to_s.split[1]
  raise ProbeFailure, "probe HTTP status #{status}" unless status == "200"

  JSON.parse(response_body)
end

def tcp_get_status(host, port, path)
  socket = TCPSocket.new(host, port)
  request = [
    "GET #{path} HTTP/1.1",
    "Host: localhost",
    "Accept: application/json",
    "Connection: close",
    "",
    ""
  ].join("\r\n")
  socket.write(request)
  response = socket.read
  socket.close

  head, response_body = response.split("\r\n\r\n", 2)
  raise ProbeFailure, "probe returned malformed HTTP" if response_body.nil?
  head.lines.first.to_s.split[1]
end

def call_request(id, name, arguments, meta)
  {
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => {"_meta" => meta, "name" => name, "arguments" => arguments}
  }
end

def self_test
  Dir.mktmpdir("sonbal-chatgpt-job-probe-") do |dir|
    socket_path = File.join(dir, "probe.sock")
    record_path = File.join(dir, "observed.jsonl")
    server = JobProbeServer.new(socket_path: socket_path, record_path: record_path)
    thread = Thread.new { server.run }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until File.socket?(socket_path)
      raise ProbeFailure, "probe socket did not become ready" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    assert((File.stat(socket_path).mode & 0o777) == 0o600,
           "probe socket mode is not 0600")

    meta = {
      "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {
        "probe" => {"version" => "1"}
      },
      "io.modelcontextprotocol/clientInfo" => {
        "name" => "sonbal-probe-self-test",
        "version" => "1"
      }
    }

    discover = unix_post(
      socket_path,
      "jsonrpc" => "2.0",
      "id" => "discover",
      "method" => "server/discover",
      "params" => {"_meta" => meta}
    )
    assert(discover.dig("result", "capabilities", "tools") == {},
           "discover tools capability mismatch")
    assert((File.stat(record_path).mode & 0o777) == 0o600,
           "probe record mode is not 0600")

    listed = unix_post(
      socket_path,
      "jsonrpc" => "2.0",
      "id" => "list",
      "method" => "tools/list",
      "params" => {"_meta" => meta}
    )
    names = listed.dig("result", "tools").map { |tool| tool.fetch("name") }
    assert(names == %w[start_process poll_process cancel_process],
           "probe tool list mismatch")

    process_arguments = {
      "argv" => ["/bin/echo", "probe"],
      "resolution" => "exact_path",
      "cwd" => "/",
      "timeout_ms" => 180_000
    }
    started = unix_post(
      socket_path,
      call_request("start", "start_process", process_arguments, meta)
    ).fetch("result").fetch("structuredContent")
    assert(started.fetch("status") == "running", "probe did not start")
    job_id = started.fetch("job_id")
    cursor0 = started.fetch("cursor")

    poll0a = unix_post(
      socket_path,
      call_request(
        "poll-0a", "poll_process",
        {"job_id" => job_id, "cursor" => cursor0}, meta
      )
    ).fetch("result").fetch("structuredContent")
    poll0b = unix_post(
      socket_path,
      call_request(
        "poll-0b", "poll_process",
        {"job_id" => job_id, "cursor" => cursor0}, meta
      )
    ).fetch("result").fetch("structuredContent")
    assert(poll0a == poll0b, "same cursor did not replay byte-identically")

    poll1 = unix_post(
      socket_path,
      call_request(
        "poll-1", "poll_process",
        {"job_id" => job_id, "cursor" => poll0a.fetch("next_cursor")}, meta
      )
    ).fetch("result").fetch("structuredContent")
    poll2 = unix_post(
      socket_path,
      call_request(
        "poll-2", "poll_process",
        {"job_id" => job_id, "cursor" => poll1.fetch("next_cursor")}, meta
      )
    ).fetch("result").fetch("structuredContent")
    assert(poll2.fetch("status") == "exited", "probe did not complete")
    assert(poll2.fetch("exit_code") == 0, "probe exit code mismatch")

    second = unix_post(
      socket_path,
      call_request("start-cancel", "start_process", process_arguments, meta)
    ).fetch("result").fetch("structuredContent")
    cancelled = unix_post(
      socket_path,
      call_request(
        "cancel", "cancel_process", {"job_id" => second.fetch("job_id")}, meta
      )
    ).fetch("result").fetch("structuredContent")
    assert(cancelled.fetch("status") == "cancelled", "probe cancel failed")

    after_cancel = unix_post(
      socket_path,
      call_request(
        "poll-cancelled", "poll_process",
        {"job_id" => second.fetch("job_id"), "cursor" => second.fetch("cursor")},
        meta
      )
    ).fetch("result").fetch("structuredContent")
    assert(after_cancel.fetch("status") == "cancelled",
           "cancelled probe did not remain terminal")

    records = File.readlines(record_path, chomp: true).map { |line| JSON.parse(line) }
    discover_record = records.find { |event| event["event"] == "server_discover" }
    assert(
      discover_record&.dig("clientCapabilities", "probe", "version") == "1",
      "sanitized client capability record missing"
    )
    assert(
      records.none? { |event| event.key?("argv") || event.key?("headers") },
      "probe record retained unapproved request data"
    )

    server.stop
    thread.join(3)
    assert(!thread.alive?, "probe server did not stop")
  ensure
    server&.stop
    thread&.join(1)
  end

  puts "[PASS] ChatGPT job API probe self-test"
end

def tcp_self_test
  Dir.mktmpdir("sonbal-chatgpt-job-probe-tcp-") do |dir|
    record_path = File.join(dir, "observed.jsonl")
    server = JobProbeServer.new(
      listen_host: "127.0.0.1",
      listen_port: 0,
      record_path: record_path
    )
    thread = Thread.new { server.run }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while server.bound_port.nil?
      raise ProbeFailure, "TCP probe listener did not become ready" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end

    assert(tcp_get_status("127.0.0.1", server.bound_port, "/") == "404",
           "TCP root discovery probe did not return HTTP 404")
    assert(
      tcp_get_status(
        "127.0.0.1", server.bound_port,
        "/.well-known/oauth-protected-resource/mcp"
      ) == "404",
      "TCP OAuth discovery probe did not return HTTP 404"
    )

    meta = {
      "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {},
      "io.modelcontextprotocol/clientInfo" => {
        "name" => "sonbal-probe-tcp-self-test",
        "version" => "1"
      }
    }
    discover = tcp_post(
      "127.0.0.1",
      server.bound_port,
      "jsonrpc" => "2.0",
      "id" => "tcp-discover",
      "method" => "server/discover",
      "params" => {"_meta" => meta}
    )
    assert(discover.dig("result", "capabilities", "tools") == {},
           "TCP discover tools capability mismatch")

    listed = tcp_post(
      "127.0.0.1",
      server.bound_port,
      "jsonrpc" => "2.0",
      "id" => "tcp-list",
      "method" => "tools/list",
      "params" => {"_meta" => meta}
    )
    names = listed.dig("result", "tools").map { |tool| tool.fetch("name") }
    assert(names == %w[start_process poll_process cancel_process],
           "TCP probe tool list mismatch")

    server.stop
    thread.join(3)
    assert(!thread.alive?, "TCP probe server did not stop")
  ensure
    server&.stop
    thread&.join(1)
  end

  puts "[PASS] ChatGPT job API probe TCP self-test"
end

def signal_shutdown_self_test
  Dir.mktmpdir("sonbal-chatgpt-job-probe-signal-") do |dir|
    socket_path = File.join(dir, "probe.sock")
    record_path = File.join(dir, "observed.jsonl")
    pid = Process.spawn(
      RbConfig.ruby,
      File.expand_path(__FILE__),
      "serve",
      socket_path,
      record_path,
      out: File::NULL,
      err: File::NULL
    )

    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      until File.socket?(socket_path)
        raise ProbeFailure, "signal-test probe did not become ready" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", pid)
      status = nil
      deadline = started + 2
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        unless waited.nil?
          status = waited.fetch(1)
          pid = nil
          break
        end
        raise ProbeFailure, "SIGTERM shutdown exceeded 2 seconds" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end

      assert(status.success?, "SIGTERM shutdown did not exit successfully")
      assert(!File.exist?(socket_path), "SIGTERM shutdown left Unix socket behind")
    ensure
      unless pid.nil?
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  puts "[PASS] ChatGPT job API probe SIGTERM self-test"
end

mode = ARGV.shift
case mode
when "serve"
  socket_path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} serve SOCKET RECORD"
  record_path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} serve SOCKET RECORD"
  abort "unexpected arguments" unless ARGV.empty?

  server = JobProbeServer.new(socket_path: socket_path, record_path: record_path)
  trap("INT") { server.stop }
  trap("TERM") { server.stop }
  puts "probe_socket=#{server.socket_path}"
  puts "probe_record=#{server.record_path}"
  $stdout.flush
  server.run
when "serve-tcp"
  host = ARGV.shift or abort "usage: #{$PROGRAM_NAME} serve-tcp HOST PORT RECORD"
  port_text = ARGV.shift or abort "usage: #{$PROGRAM_NAME} serve-tcp HOST PORT RECORD"
  record_path = ARGV.shift or abort "usage: #{$PROGRAM_NAME} serve-tcp HOST PORT RECORD"
  abort "unexpected arguments" unless ARGV.empty?
  abort "TCP probe host must be 127.0.0.1" unless host == "127.0.0.1"
  abort "invalid TCP probe port" unless port_text.match?(/\A[0-9]+\z/)
  port = Integer(port_text, 10)
  abort "TCP probe port must be 1024..65535" unless port.between?(1024, 65_535)

  server = JobProbeServer.new(
    listen_host: host,
    listen_port: port,
    record_path: record_path
  )
  trap("INT") { server.stop }
  trap("TERM") { server.stop }
  puts "probe_url=http://#{host}:#{port}/mcp"
  puts "probe_record=#{server.record_path}"
  $stdout.flush
  server.run
when "self-test"
  abort "unexpected arguments" unless ARGV.empty?
  self_test
  tcp_self_test
  signal_shutdown_self_test
else
  abort "usage: #{$PROGRAM_NAME} {serve SOCKET RECORD|serve-tcp HOST PORT RECORD|self-test}"
end
