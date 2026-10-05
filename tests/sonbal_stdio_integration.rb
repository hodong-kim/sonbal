# =============================================================================
# sonbal_stdio_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "base64"
require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"

TIMEOUT_SECONDS = 30
MAX_MESSAGE_BYTES = 1_048_576
MAX_GENERIC_JSON_TEXT_BYTES = 1_024
RUN_PROCESS_PATH = "/usr/local/bin:/usr/bin:/bin".freeze
RELEASE_IDENTITY_SOURCE = File.expand_path(
  "../src/sonbal-release_identity.ads",
  __dir__
)


def release_identity_value(name)
  source = File.read(RELEASE_IDENTITY_SOURCE, encoding: "UTF-8")
  pattern =
    /^\s*#{Regexp.escape(name)}\s*:\s*constant\s+String\s*:=\s*"([^"]+)";/
  match = source.match(pattern)
  raise "missing release identity #{name}" if match.nil?

  match[1]
end

SERVER_VERSION = release_identity_value("Version")
SERVER_REVISION = release_identity_value("Revision")

EXPECTED_TOOL_NAMES = %w[
  ping
  rotate_workspace_token
  run_process
  start_process
  poll_process
  cancel_process
  read_file
].freeze

REQUEST_META =
  %q("_meta":{) +
  %q("io.modelcontextprotocol/protocolVersion":"2026-07-28",) +
  %q("io.modelcontextprotocol/clientCapabilities":{},) +
  %q("io.modelcontextprotocol/clientInfo":{) +
  %q("name":"integration","version":"1"}})

DISCOVER_REQUEST =
  %q({"jsonrpc":"2.0","id":"discover","method":"server/discover",) +
  %Q("params":{#{REQUEST_META}}})
TOOLS_LIST_REQUEST =
  %q({"jsonrpc":"2.0","id":2,"method":"tools/list",) +
  %Q("params":{#{REQUEST_META}}})
PING_REQUEST =
  %q({"jsonrpc":"2.0","id":"p\u0069ng","method":"tools/call",) +
  %Q("params":{#{REQUEST_META},"name":"ping","arguments":{}}})
PING_OPEN_REQUEST =
  %q({"jsonrpc":"2.0","id":"ping-open","method":"tools/call",) +
  %Q("params":{#{REQUEST_META},"name":"ping","arguments":{}}})

SERVER_INFO_META =
  %q("_meta":{"io.modelcontextprotocol/serverInfo":{) +
  %Q("name":"sonbal","version":"#{SERVER_VERSION}"}})
DISCOVER_RESPONSE =
  %q({"jsonrpc":"2.0","id":"discover","result":{) +
  %q("resultType":"complete","supportedVersions":["2026-07-28"],) +
  %q("capabilities":{"tools":{}},) +
  SERVER_INFO_META +
  %q(,"ttlMs":0,"cacheScope":"private"}})

PING_TEXT = "sonbal #{SERVER_VERSION}-#{SERVER_REVISION}"
PING_STRUCTURED_CONTENT =
  %Q("structuredContent":{"version":"#{SERVER_VERSION}",) +
  %Q("revision":"#{SERVER_REVISION}"},)
PING_RESPONSE =
  %q({"jsonrpc":"2.0","id":"p\u0069ng","result":{) +
  %Q("resultType":"complete","content":[{"type":"text",) +
  %Q("text":"#{PING_TEXT}"}],) +
  PING_STRUCTURED_CONTENT +
  %q("isError":false,) + SERVER_INFO_META + %q(}})
PING_OPEN_RESPONSE =
  %q({"jsonrpc":"2.0","id":"ping-open","result":{"resultType":"complete",) +
  %Q("content":[{"type":"text","text":"#{PING_TEXT}"}],) +
  PING_STRUCTURED_CONTENT +
  %q("isError":false,) + SERVER_INFO_META + %q(}})

FULL_INPUT =
  [DISCOVER_REQUEST, TOOLS_LIST_REQUEST, PING_REQUEST].join("\n") + "\n"


def close_io(io)
  io.close unless io.nil? || io.closed?
rescue IOError
  nil
end


def tool_request(id, name, arguments = {})
  JSON.generate(
    "jsonrpc" => "2.0",
    "id" => id,
    "method" => "tools/call",
    "params" => {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {
          "name" => "integration",
          "version" => "1"
        }
      },
      "name" => name,
      "arguments" => arguments
    }
  )
end


def process_response(id, stdout_text)
  {
    "jsonrpc" => "2.0",
    "id" => id,
    "result" => {
      "resultType" => "complete",
      "content" => [{"type" => "text", "text" => "exited"}],
      "structuredContent" => {
        "status" => "exited",
        "stdout" => {
          "encoding" => "utf8",
          "bytes" => stdout_text.bytesize,
          "data" => stdout_text,
          "truncated" => false
        },
        "stderr" => {
          "encoding" => "utf8",
          "bytes" => 0,
          "data" => "",
          "truncated" => false
        },
        "exit_code" => 0
      },
      "isError" => false,
      "_meta" => {
        "io.modelcontextprotocol/serverInfo" => {
          "name" => "sonbal",
          "version" => SERVER_VERSION
        }
      }
    }
  }
end


def current_workspace_token
  Thread.current[:sonbal_workspace_token] ||
    raise("test process has no current workspace token")
end


def current_workspace_root
  Thread.current[:sonbal_workspace_root] ||
    raise("test process has no current workspace root")
end


def run_process_request(
  id,
  argv,
  resolution: "exact_path",
  cwd: nil,
  timeout_ms: 2_000,
  workspace_token: nil
)
  tool_request(
    id,
    "run_process",
    "workspace_token" =>
      (workspace_token || current_workspace_token),
    "argv" => argv,
    "resolution" => resolution,
    "cwd" => (cwd || current_workspace_root),
    "timeout_ms" => timeout_ms
  )
end

def start_process_request(
  id,
  argv,
  resolution: "exact_path",
  cwd: nil,
  timeout_ms: 5_000,
  workspace_token: nil
)
  tool_request(
    id,
    "start_process",
    "workspace_token" =>
      (workspace_token || current_workspace_token),
    "argv" => argv,
    "resolution" => resolution,
    "cwd" => (cwd || current_workspace_root),
    "timeout_ms" => timeout_ms
  )
end


def poll_process_request(id, job_id, cursor)
  tool_request(id, "poll_process", "job_id" => job_id, "cursor" => cursor)
end


def cancel_process_request(id, job_id)
  tool_request(id, "cancel_process", "job_id" => job_id)
end


def read_file_request(
  id,
  path,
  offset: nil,
  maximum_bytes: nil,
  expected_revision: nil,
  workspace_token: nil
)
  arguments = {
    "workspace_token" => (workspace_token || current_workspace_token),
    "path" => path
  }
  arguments["offset"] = offset unless offset.nil?
  arguments["maximum_bytes"] = maximum_bytes unless maximum_bytes.nil?
  arguments["expected_revision"] = expected_revision unless
    expected_revision.nil?
  tool_request(id, "read_file", arguments)
end


def rotate_workspace_token(stdin, stdout, root, label)
  prepared = exchange(
    stdin,
    stdout,
    tool_request("#{label}-prepare", "rotate_workspace_token", "root" => root)
  )
  prepared_content = tool_structured_content(
    prepared,
    "#{label}-prepare",
    "prepared",
    is_error: false
  )
  operation_id = prepared_content.fetch("operation_id")

  committed = exchange(
    stdin,
    stdout,
    tool_request(
      "#{label}-commit",
      "rotate_workspace_token",
      "root" => root,
      "operation_id" => operation_id
    )
  )
  tool_structured_content(
    committed,
    "#{label}-commit",
    "rotated",
    is_error: false
  )
end




def tool_structured_content(response, id, status, is_error:)
  assert(response.fetch("jsonrpc") == "2.0", "tool response JSON-RPC mismatch")
  assert(response.fetch("id") == id, "tool response id mismatch")
  result = response["result"]
  raise "tool response missing result: #{response.inspect}" if result.nil?
  assert(
    result.fetch("content") == [{"type" => "text", "text" => status}],
    "tool response text status mismatch"
  )
  assert(result.fetch("isError") == is_error, "tool response isError mismatch")
  structured = result.fetch("structuredContent")
  assert(structured.fetch("status") == status, "tool structured status mismatch")
  structured
end


def process_structured_content(response, id, status, is_error:)
  assert(response.fetch("jsonrpc") == "2.0", "process response JSON-RPC mismatch")
  assert(response.fetch("id") == id, "process response id mismatch")

  result = response.fetch("result")
  assert(
    result.fetch("content") == [{"type" => "text", "text" => status}],
    "process response text status mismatch"
  )
  assert(result.fetch("isError") == is_error, "process isError mismatch")

  structured = result.fetch("structuredContent")
  assert(structured.fetch("status") == status, "process status mismatch")
  structured
end


def decode_process_stream(stream)
  bytes =
    case stream.fetch("encoding")
    when "utf8"
      stream.fetch("data").b
    when "base64"
      Base64.strict_decode64(stream.fetch("data"))
    else
      raise "unknown process stream encoding: #{stream.fetch("encoding").inspect}"
    end

  assert(
    bytes.bytesize == stream.fetch("bytes"),
    "process stream byte count did not match decoded data"
  )
  bytes
end


def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end


def wait_process_absent(pid, timeout_seconds: 2.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  loop do
    return true unless process_alive?(pid)
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.02
  end
end


def exchange(stdin_write, stdout_read, request)
  stdin_write.write(request)
  stdin_write.write("\n")
  stdin_write.flush

  response = stdout_read.gets
  raise "server closed stdout before responding" if response.nil?

  JSON.parse(response)
end


def run_live_server(executable, environment: {}, arguments: [])
  stdin_read, stdin_write = IO.pipe
  stdout_read, stdout_write = IO.pipe
  stderr_read, stderr_write = IO.pipe

  [stdin_read, stdin_write, stdout_read, stdout_write,
   stderr_read, stderr_write].each(&:binmode)

  pid = Process.spawn(
    environment,
    executable,
    *arguments,
    in: stdin_read,
    out: stdout_write,
    err: stderr_write
  )

  close_io(stdin_read)
  close_io(stdout_write)
  close_io(stderr_write)

  stderr_thread = Thread.new { stderr_read.read rescue "" }
  status = nil
  value = nil
  workspace_root = Dir.mktmpdir("sonbal-stdio-workspace-")

  begin
    Timeout.timeout(TIMEOUT_SECONDS) do
      open_content = rotate_workspace_token(
        stdin_write,
        stdout_read,
        workspace_root,
        "workspace-open"
      )
      Thread.current[:sonbal_workspace_root] = workspace_root
      Thread.current[:sonbal_workspace_token] =
        open_content.fetch("workspace_token")

      value = yield(stdin_write, stdout_read)
      Thread.current[:sonbal_workspace_root] = nil
      Thread.current[:sonbal_workspace_token] = nil
      close_io(stdin_write)
      _waited_pid, status = Process.wait2(pid)
    end
  ensure
    close_io(stdin_write)
    unless status
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  [value, stderr_thread.value, status]
ensure
  close_io(stdin_read)
  close_io(stdin_write)
  close_io(stdout_read)
  close_io(stdout_write)
  close_io(stderr_read)
  close_io(stderr_write)
  stderr_thread&.join(1)
  Thread.current[:sonbal_workspace_root] = nil
  Thread.current[:sonbal_workspace_token] = nil
  if defined?(workspace_root) && workspace_root && File.exist?(workspace_root)
    FileUtils.remove_entry(workspace_root)
  end
end


def run_server(executable, input, close_stdout_reader: false)
  stdin_read, stdin_write = IO.pipe
  stdout_read, stdout_write = IO.pipe
  stderr_read, stderr_write = IO.pipe

  [stdin_read, stdin_write, stdout_read, stdout_write,
   stderr_read, stderr_write].each(&:binmode)

  if close_stdout_reader
    stdout_read.close
    stdout_read = nil
  end

  pid = Process.spawn(
    executable,
    in: stdin_read,
    out: stdout_write,
    err: stderr_write
  )

  close_io(stdin_read)
  close_io(stdout_write)
  close_io(stderr_write)

  stdout_thread =
    stdout_read.nil? ? nil : Thread.new { stdout_read.read rescue "" }
  stderr_thread = Thread.new { stderr_read.read rescue "" }
  status = nil

  begin
    Timeout.timeout(TIMEOUT_SECONDS) do
      begin
        stdin_write.write(input)
      rescue Errno::EPIPE
        nil
      ensure
        close_io(stdin_write)
      end

      _waited_pid, status = Process.wait2(pid)
    end
  rescue Timeout::Error
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
    raise "server exceeded #{TIMEOUT_SECONDS} seconds"
  ensure
    close_io(stdin_write)
  end

  stdout = stdout_thread.nil? ? "" : stdout_thread.value
  stderr = stderr_thread.value
  [stdout, stderr, status]
ensure
  close_io(stdin_read)
  close_io(stdin_write)
  close_io(stdout_read)
  close_io(stdout_write)
  close_io(stderr_read)
  close_io(stderr_write)
  begin
    stdout_thread&.join(1)
    stderr_thread&.join(1)
  rescue StandardError
    nil
  end
end


def assert(condition, message)
  raise message unless condition
end


def assert_failed_exit(status, label)
  assert(!status.nil?, "#{label}: process status is missing")
  assert(status.exited?, "#{label}: process was terminated by a signal")
  assert(!status.success?, "#{label}: process unexpectedly succeeded")
end


def run_case(name)
  yield
  puts "[PASS] #{name}"
  true
rescue StandardError => error
  warn "[FAIL] #{name}: #{error.message}"
  false
end


def exercise_work_slot_capacity(executable, capacity, arguments: [])
  Dir.mktmpdir("sonbal-work-slots-") do |directory|
    started_path = File.join(directory, "started")
    release_path = File.join(directory, "release")
    _value, stderr, status = run_live_server(
      executable,
      arguments: arguments
    ) do |stdin, stdout|
      script =
        "printf x >> \"$1\"; " \
        "while [ ! -e \"$2\" ]; do /bin/sleep 0.02; done"
      requests = (capacity + 1).times.map do |index|
        run_process_request(
          "capacity-run-#{capacity}-#{index}",
          ["/bin/sh", "-c", script, "slot", started_path, release_path],
          timeout_ms: 10_000
        )
      end
      stdin.write(requests.join("\n") + "\n")
      stdin.flush

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
      loop do
        started =
          File.exist?(started_path) ? File.binread(started_path).bytesize : 0
        break if started >= capacity
        raise "configured work slots did not become active" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.02
      end
      assert(File.binread(started_path).bytesize == capacity,
             "scheduler exceeded configured work slots")
      sleep 0.15
      assert(File.binread(started_path).bytesize == capacity,
             "queued child started before slot release")

      File.write(release_path, "go")
      exited = 0
      busy = 0
      (capacity + 1).times do
        line = stdout.gets
        raise "server closed stdout during capacity acceptance" if line.nil?
        response = JSON.parse(line)
        id = response.fetch("id")
        response_status = response.dig("result", "structuredContent", "status")
        case response_status
        when "exited"
          content = process_structured_content(
            response, id, "exited", is_error: false
          )
          assert(content.fetch("exit_code") == 0, "capacity child exit changed")
          exited += 1
        when "execution_busy"
          process_structured_content(
            response, id, "execution_busy", is_error: true
          )
          busy += 1
        else
          raise "unexpected capacity response status #{response_status.inspect}"
        end
      end
      assert(exited == capacity, "capacity execution count changed")
      assert(busy == 1, "capacity overflow was not rejected exactly once")
      assert(
        File.binread(started_path).bytesize == capacity,
        "capacity rejection queued a child for later execution"
      )
    end
    [stderr, status]
  end
end

product_executable = File.expand_path(ARGV.fetch(0))
unless File.file?(product_executable) && File.executable?(product_executable)
  abort "integration executable is missing or not executable: #{product_executable}"
end

fixture_executable = File.expand_path(ARGV.fetch(1))
unless File.file?(fixture_executable) && File.executable?(fixture_executable)
  abort "stdio fixture is missing or not executable: #{fixture_executable}"
end

process_fixture_executable = File.expand_path(ARGV.fetch(2))
unless File.file?(process_fixture_executable) &&
       File.executable?(process_fixture_executable)
  abort "process fixture is missing or not executable: " \
    "#{process_fixture_executable}"
end

results = []

results << run_case("security check redacts ambient credentials") do
  secrets = {
    "CONTROL_PLANE_API_KEY" => "integration-control-secret",
    "OPENAI_API_KEY" => "integration-fallback-secret",
    "OPENAI_ADMIN_KEY" => "integration-admin-secret",
    "SSH_AUTH_SOCK" => "/integration/private-agent.sock"
  }
  stdout, stderr, status = Open3.capture3(
    secrets,
    product_executable,
    "--security-check",
    unsetenv_others: true
  )

  assert_failed_exit(status, "unsafe security check")
  assert(stderr.empty?, "security check wrote to stderr")
  secrets.each_key do |name|
    assert(
      stdout.include?("#{name}=present\n"),
      "security check missed #{name}"
    )
  end
  secrets.each_value do |secret|
    assert(!stdout.include?(secret), "security check leaked a secret value")
  end
  assert(stdout.include?("result=unsafe\n"), "unsafe result was not reported")
end

results << run_case("maximum work slot configuration has no CLI override") do
  ["--work-slots", "--max-work-slots"].each do |argument|
    stdout, stderr, status = Open3.capture3(product_executable, argument, "16")

    assert_failed_exit(status, "unsupported #{argument} CLI")
    assert(stdout.empty?, "unsupported #{argument} CLI wrote protocol stdout")
    assert(
      stderr.empty?,
      "unsupported #{argument} CLI wrote to stderr instead of native diagnostics"
    )
  end
end

results << run_case("product runtime enforces shared file creation mask") do
  _value, stderr, status =
    run_live_server(product_executable) do |stdin, stdout|
      workspace_root = current_workspace_root
      shared_directory = File.join(workspace_root, "shared-directory")
      shared_file = File.join(workspace_root, "shared-file")

      response = exchange(
        stdin,
        stdout,
        run_process_request(
          "product-umask",
          [
            "/bin/sh",
            "-c",
            'set -e; umask; mkdir "$1"; : > "$2"',
            "create-shared",
            shared_directory,
            shared_file
          ]
        )
      )
      content = process_structured_content(
        response,
        "product-umask",
        "exited",
        is_error: false
      )
      assert(content.fetch("exit_code") == 0, "umask probe exit changed")
      assert(
        decode_process_stream(content.fetch("stdout")) == "0002\n".b,
        "product child did not inherit the shared file creation mask"
      )

      directory_stat = File.stat(shared_directory)
      file_stat = File.stat(shared_file)
      assert(
        directory_stat.mode & 0o777 == 0o775,
        "child directory did not preserve shared group-write mode"
      )
      assert(
        file_stat.mode & 0o777 == 0o664,
        "child file did not preserve shared group-write mode"
      )
    end

  assert(status.success?, "umask-policy server returned #{status.inspect}")
  assert(stderr.empty?, "umask-policy server wrote to stderr")
end

# Runtime protocol tests use the test-only stdio fixture so host production
# configuration cannot change source-tree acceptance behavior.
executable = fixture_executable

results << run_case("devnull stdin exits cleanly") do
  pid = Process.spawn(
    executable,
    in: File::NULL,
    out: File::NULL,
    err: File::NULL
  )
  status = nil

  begin
    Timeout.timeout(2) do
      _waited_pid, status = Process.wait2(pid)
    end
  ensure
    unless status
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  assert(status.success?, "devnull stdin did not exit cleanly")
end

results << run_case("complete local MCP round trip") do
  stdout, stderr, status = run_server(executable, FULL_INPUT)
  lines = stdout.lines(chomp: true)

  assert(status.success?, "server returned #{status.inspect}")
  assert(lines.length == 3, "protocol stdout line count did not match")
  assert(lines.fetch(0) == DISCOVER_RESPONSE, "discovery response did not match")

  tools_response = JSON.parse(lines.fetch(1))
  tools = tools_response.dig("result", "tools")
  tool_names = tools&.map { |tool| tool["name"] }
  assert(tool_names == EXPECTED_TOOL_NAMES, "unexpected tool list: #{tool_names.inspect}")
  run_process_tool = tools.find { |tool| tool["name"] == "run_process" }
  run_process_schema = run_process_tool.fetch("inputSchema")
  assert(
    run_process_schema.fetch("additionalProperties") == false,
    "run_process schema permits undocumented arguments"
  )
  token_schema =
    run_process_tool&.dig("inputSchema", "properties", "workspace_token")
  assert(
    token_schema == {"type" => "string", "minLength" => 1, "maxLength" => 66},
    "run_process did not advertise the workspace-token contract"
  )
  argv_item_schema =
    run_process_tool&.dig("inputSchema", "properties", "argv", "items")
  assert(
    argv_item_schema == {"type" => "string", "maxLength" => 32_768},
    "run_process did not advertise the aggregate-sized argv element bound"
  )
  cwd_schema = run_process_tool&.dig("inputSchema", "properties", "cwd")
  assert(
    cwd_schema == {
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 4096,
      "pattern" => "^/([^\\n]|\\n)*$"
    },
    "run_process did not advertise the absolute cwd contract"
  )
  cwd_pattern = Regexp.new("\\A(?:#{cwd_schema.fetch("pattern")})\\z")
  assert(
    cwd_pattern.match?("/") &&
      cwd_pattern.match?("/tmp/project") &&
      !cwd_pattern.match?("relative/path"),
    "run_process cwd pattern did not preserve whole-string absolute paths"
  )

  assert(lines.fetch(2) == PING_RESPONSE, "ping response did not match")
  assert(stderr.empty?, "successful round trip wrote to stderr")
end

results << run_case("default maximum work slot capacity is exactly sixteen") do
  stderr, status = exercise_work_slot_capacity(executable, 16)
  assert(status.success?, "default work-slot run returned #{status.inspect}")
  assert(stderr.empty?, "default work-slot run wrote to stderr")
end

results << run_case("configured maximum work slot boundaries are enforced") do
  [1, 64].each do |capacity|
    stderr, status = exercise_work_slot_capacity(
      fixture_executable,
      capacity,
      arguments: [capacity.to_s]
    )
    assert(
      status.success?,
      "configured #{capacity}-slot fixture returned #{status.inspect}"
    )
    assert(
      stderr.empty?,
      "configured #{capacity}-slot fixture wrote to stderr"
    )
  end
end

results << run_case("run_process executes and settles request ownership") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    response = exchange(
      stdin,
      stdout,
      run_process_request("process-echo", ["/bin/echo", "sonbal"])
    )
    assert(
      response == process_response("process-echo", "sonbal\n"),
      "run_process response did not match the frozen process wire contract"
    )
  end

  assert(status.success?, "run_process execution returned #{status.inspect}")
  assert(stderr.empty?, "run_process execution wrote to stderr")
end

results << run_case("read_file preserves bounded workspace semantics") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    root = current_workspace_root
    old_token = current_workspace_token
    text = "alpha\nbeta\n".b
    File.binwrite(File.join(root, "sample.txt"), text)
    Dir.mkdir(File.join(root, "nested"))
    File.binwrite(File.join(root, "nested", "item.txt"), "nested-data")
    File.binwrite(
      File.join(root, "binary.bin"),
      [0xff, 0x00, 0x41, 0x0a].pack("C*")
    )
    File.symlink("sample.txt", File.join(root, "sample-link"))
    Dir.mkdir(File.join(root, "real-directory"))
    File.binwrite(File.join(root, "real-directory", "item.txt"), "symlink-data")
    File.symlink("real-directory", File.join(root, "directory-link"))
    File.binwrite(File.join(root, "changing.txt"), "old")

    sparse_offset = 4_294_967_296 + 4_096
    File.open(File.join(root, "sparse.bin"), "wb") do |file|
      file.seek(sparse_offset)
      file.write("mark")
    end

    first = exchange(
      stdin,
      stdout,
      read_file_request("read-file-first", "sample.txt", maximum_bytes: 6)
    )
    first_content = tool_structured_content(
      first, "read-file-first", "ok", is_error: false
    )
    first_revision = first_content.fetch("revision")
    assert(
      first_revision.match?(/\Ar1-[0-9a-f]{96}\z/),
      "read_file revision is not canonical"
    )
    assert(first_content.fetch("file_size") == text.bytesize,
           "read_file file size changed")
    assert(first_content.fetch("offset") == 0, "read_file offset changed")
    assert(first_content.fetch("next_offset") == 6,
           "read_file next offset changed")
    assert(!first_content.fetch("eof"), "read_file reported early EOF")
    assert(
      decode_process_stream(first_content.fetch("content")) == "alpha\n".b,
      "read_file first content changed"
    )

    second = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-second",
        "sample.txt",
        offset: first_content.fetch("next_offset"),
        maximum_bytes: 16,
        expected_revision: first_revision
      )
    )
    second_content = tool_structured_content(
      second, "read-file-second", "ok", is_error: false
    )
    assert(second_content.fetch("revision") == first_revision,
           "read_file revision changed without a file mutation")
    assert(second_content.fetch("next_offset") == text.bytesize,
           "read_file terminal offset changed")
    assert(second_content.fetch("eof"), "read_file terminal EOF is false")
    assert(
      decode_process_stream(second_content.fetch("content")) == "beta\n".b,
      "read_file second content changed"
    )

    eof_response = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-eof",
        "sample.txt",
        offset: text.bytesize,
        expected_revision: first_revision
      )
    )
    eof_content = tool_structured_content(
      eof_response, "read-file-eof", "ok", is_error: false
    )
    assert(eof_content.fetch("eof"), "read_file exact-size offset is not EOF")
    assert(eof_content.dig("content", "bytes") == 0,
           "read_file EOF returned content")

    nested = exchange(
      stdin,
      stdout,
      read_file_request("read-file-nested", "nested/item.txt")
    )
    nested_content = tool_structured_content(
      nested, "read-file-nested", "ok", is_error: false
    )
    assert(
      decode_process_stream(nested_content.fetch("content")) == "nested-data".b,
      "read_file nested traversal changed content"
    )

    binary = exchange(
      stdin,
      stdout,
      read_file_request("read-file-binary", "binary.bin")
    )
    binary_content = tool_structured_content(
      binary, "read-file-binary", "ok", is_error: false
    )
    assert(binary_content.dig("content", "encoding") == "base64",
           "read_file binary content was not lossless base64")
    assert(
      decode_process_stream(binary_content.fetch("content")) ==
        [0xff, 0x00, 0x41, 0x0a].pack("C*"),
      "read_file binary bytes changed"
    )

    mismatch = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-revision-mismatch",
        "sample.txt",
        expected_revision: "r1-" + ("0" * 96)
      )
    )
    tool_structured_content(
      mismatch,
      "read-file-revision-mismatch",
      "revision_mismatch",
      is_error: true
    )

    changing = exchange(
      stdin,
      stdout,
      read_file_request("read-file-changing", "changing.txt")
    )
    changing_content = tool_structured_content(
      changing, "read-file-changing", "ok", is_error: false
    )
    File.binwrite(File.join(root, "changing.txt"), "new-longer")
    changed = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-changed",
        "changing.txt",
        expected_revision: changing_content.fetch("revision")
      )
    )
    tool_structured_content(
      changed, "read-file-changed", "revision_mismatch", is_error: true
    )

    sparse = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-sparse",
        "sparse.bin",
        offset: sparse_offset,
        maximum_bytes: 4
      )
    )
    sparse_content = tool_structured_content(
      sparse, "read-file-sparse", "ok", is_error: false
    )
    assert(sparse_content.fetch("offset") == sparse_offset,
           "read_file truncated a 4 GiB+ offset")
    assert(sparse_content.fetch("file_size") == sparse_offset + 4,
           "read_file sparse file size changed")
    assert(sparse_content.fetch("eof"), "read_file sparse marker is not EOF")
    assert(
      decode_process_stream(sparse_content.fetch("content")) == "mark".b,
      "read_file sparse marker changed"
    )

    range = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-range",
        "sample.txt",
        offset: text.bytesize + 1
      )
    )
    tool_structured_content(
      range, "read-file-range", "offset_out_of_range", is_error: true
    )

    symlink = exchange(
      stdin,
      stdout,
      read_file_request("read-file-symlink", "sample-link")
    )
    tool_structured_content(
      symlink, "read-file-symlink", "path_refused", is_error: true
    )

    intermediate_symlink = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-intermediate-symlink",
        "directory-link/item.txt"
      )
    )
    tool_structured_content(
      intermediate_symlink,
      "read-file-intermediate-symlink",
      "path_refused",
      is_error: true
    )

    sleep 1.05
    rotated = rotate_workspace_token(
      stdin, stdout, root, "read-file-replacement-token"
    )
    replacement_token = rotated.fetch("workspace_token")

    stale = exchange(
      stdin,
      stdout,
      read_file_request(
        "read-file-stale",
        "sample.txt",
        workspace_token: old_token
      )
    )
    tool_structured_content(
      stale, "read-file-stale", "stale_workspace_token", is_error: true
    )

    saved_root = "#{root}.read-file-original"
    begin
      File.rename(root, saved_root)
      Dir.mkdir(root, 0o755)
      File.binwrite(File.join(root, "sample.txt"), "replacement")

      replaced = exchange(
        stdin,
        stdout,
        read_file_request(
          "read-file-root-replaced",
          "sample.txt",
          workspace_token: replacement_token
        )
      )
      tool_structured_content(
        replaced,
        "read-file-root-replaced",
        "path_refused",
        is_error: true
      )
    ensure
      FileUtils.remove_entry(root) if File.exist?(root)
      File.rename(saved_root, root) if File.exist?(saved_root)
    end
  end

  assert(status.success?, "read_file execution returned #{status.inspect}")
  assert(stderr.empty?, "read_file execution wrote to stderr")
end

results << run_case("server-owned process tools preserve workspace-token freshness") do

  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    old_token = current_workspace_token
    workspace_root = current_workspace_root

    started = exchange(
      stdin,
      stdout,
      start_process_request(
        "job-live-start",
        ["/bin/sh", "-c", "printf first; sleep 2; printf second"],
        timeout_ms: 5_000
      )
    )
    start_content = tool_structured_content(
      started,
      "job-live-start",
      "running",
      is_error: false
    )
    job_id = start_content.fetch("job_id")
    initial_cursor = start_content.fetch("cursor")

    live = nil
    live_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.75
    loop do
      live = exchange(
        stdin,
        stdout,
        poll_process_request("job-live-poll", job_id, initial_cursor)
      )
      live_content = live.dig("result", "structuredContent") || {}
      break if
        live_content["status"] == "running" &&
        live_content.dig("stdout", "bytes").to_i > 0
      raise "live job output did not appear before process exit" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= live_deadline
      sleep 0.02
    end

    live_content = tool_structured_content(
      live,
      "job-live-poll",
      "running",
      is_error: false
    )
    assert(
      decode_process_stream(live_content.fetch("stdout")) == "first".b,
      "poll_process did not expose stdout while the child remained alive"
    )

    replay = exchange(
      stdin,
      stdout,
      poll_process_request("job-live-replay", job_id, initial_cursor)
    )
    replay_content = tool_structured_content(
      replay,
      "job-live-replay",
      "running",
      is_error: false
    )
    assert(
      replay_content.fetch("stdout") == live_content.fetch("stdout") &&
        replay_content.fetch("next_cursor") == live_content.fetch("next_cursor"),
      "same live cursor did not replay the same retained increment"
    )

    sleep 1.05
    replacement_content = rotate_workspace_token(
      stdin,
      stdout,
      workspace_root,
      "workspace-token-replacement"
    )
    new_token = replacement_content.fetch("workspace_token")
    assert(
      new_token != old_token,
      "workspace token rotation reused the old token"
    )
    Thread.current[:sonbal_workspace_token] = new_token

    stale_sync = exchange(
      stdin,
      stdout,
      run_process_request(
        "workspace-old-token-run",
        ["/usr/bin/true"],
        workspace_token: old_token
      )
    )
    process_structured_content(
      stale_sync,
      "workspace-old-token-run",
      "stale_workspace_token",
      is_error: true
    )

    stale_job = exchange(
      stdin,
      stdout,
      start_process_request(
        "workspace-old-token-job",
        ["/usr/bin/true"],
        workspace_token: old_token
      )
    )
    tool_structured_content(
      stale_job,
      "workspace-old-token-job",
      "stale_workspace_token",
      is_error: true
    )


    current = exchange(
      stdin,
      stdout,
      run_process_request(
        "workspace-current-token-run",
        ["/usr/bin/true"]
      )
    )
    process_structured_content(
      current,
      "workspace-current-token-run",
      "exited",
      is_error: false
    )

    terminal = nil
    cursor = live_content.fetch("next_cursor")
    terminal_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4.0
    loop do
      terminal = exchange(
        stdin,
        stdout,
        poll_process_request("job-token-rotation-poll", job_id, cursor)
      )
      terminal_status = terminal.dig("result", "structuredContent", "status")
      break if terminal_status == "exited"
      raise "token rotation disturbed accepted live job settlement" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= terminal_deadline
      sleep 0.02
    end
    terminal_content = tool_structured_content(
      terminal,
      "job-token-rotation-poll",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(terminal_content.fetch("stdout")).include?("second"),
      "token rotation cancelled or truncated already accepted job work"
    )

    outside = exchange(
      stdin,
      stdout,
      run_process_request(
        "outside-workspace",
        ["/usr/bin/true"],
        cwd: "/",
        workspace_token: new_token
      )
    )
    process_structured_content(
      outside,
      "outside-workspace",
      "outside_workspace",
      is_error: true
    )

    second = exchange(
      stdin,
      stdout,
      start_process_request(
        "job-cancel-start",
        ["/bin/sleep", "30"],
        timeout_ms: 30_000,
        workspace_token: new_token
      )
    )
    second_content = tool_structured_content(
      second,
      "job-cancel-start",
      "running",
      is_error: false
    )
    second_id = second_content.fetch("job_id")
    second_cursor = second_content.fetch("cursor")

    cancel = exchange(
      stdin,
      stdout,
      cancel_process_request("job-cancel", second_id)
    )
    tool_structured_content(cancel, "job-cancel", "cancelling", is_error: false)

    cancel_terminal = nil
    cancel_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4.0
    loop do
      cancel_terminal = exchange(
        stdin,
        stdout,
        poll_process_request("job-cancel-poll", second_id, second_cursor)
      )
      cancel_status =
        cancel_terminal.dig("result", "structuredContent", "status")
      break if cancel_status == "cancelled"
      raise "explicit cancel did not settle server-owned job" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= cancel_deadline
      sleep 0.02
    end
    tool_structured_content(
      cancel_terminal,
      "job-cancel-poll",
      "cancelled",
      is_error: false
    )


    sleep 1.05
    prepared_open = exchange(
      stdin,
      stdout,
      tool_request(
        "workspace-lost-open-prepare",
        "rotate_workspace_token",
        "root" => workspace_root
      )
    )
    prepared_content = tool_structured_content(
      prepared_open,
      "workspace-lost-open-prepare",
      "prepared",
      is_error: false
    )
    lost_operation_id = prepared_content.fetch("operation_id")

    lost_open = exchange(
      stdin,
      stdout,
      tool_request(
        "workspace-lost-open-commit",
        "rotate_workspace_token",
        "root" => workspace_root,
        "operation_id" => lost_operation_id
      )
    )
    lost_open_content = tool_structured_content(
      lost_open,
      "workspace-lost-open-commit",
      "rotated",
      is_error: false
    )
    lost_token = lost_open_content.fetch("workspace_token")

    replayed_open = exchange(
      stdin,
      stdout,
      tool_request(
        "workspace-lost-open-replay",
        "rotate_workspace_token",
        "root" => workspace_root,
        "operation_id" => lost_operation_id
      )
    )
    replayed_content = tool_structured_content(
      replayed_open,
      "workspace-lost-open-replay",
      "rotated",
      is_error: false
    )
    assert(
      replayed_content.fetch("workspace_token") == lost_token &&
        replayed_content.fetch("operation_id") == lost_operation_id,
      "lost rotation response did not replay the same workspace token"
    )

    cooldown_prepare = exchange(
      stdin,
      stdout,
      tool_request(
        "workspace-cooldown-prepare",
        "rotate_workspace_token",
        "root" => workspace_root
      )
    )
    cooldown_prepared = tool_structured_content(
      cooldown_prepare,
      "workspace-cooldown-prepare",
      "prepared",
      is_error: false
    )
    cooldown_commit = exchange(
      stdin,
      stdout,
      tool_request(
        "workspace-cooldown-commit",
        "rotate_workspace_token",
        "root" => workspace_root,
        "operation_id" => cooldown_prepared.fetch("operation_id")
      )
    )
    tool_structured_content(
      cooldown_commit,
      "workspace-cooldown-commit",
      "cooldown",
      is_error: true
    )

  end

  assert(status.success?, "server-owned process tools returned #{status.inspect}")
  assert(stderr.empty?, "server-owned process tools wrote to stderr")
end

results << run_case("stdio job and synchronous execution share capacity") do
  _value, stderr, status = run_live_server(
    fixture_executable,
    arguments: ["1"]
  ) do |stdin, stdout|
    File.binwrite(
      File.join(current_workspace_root, "capacity-read.txt"),
      "capacity-read"
    )

    started = exchange(
      stdin,
      stdout,
      start_process_request(
        "mixed-capacity-job",
        ["/bin/sleep", "30"],
        timeout_ms: 30_000
      )
    )
    start_content = tool_structured_content(
      started,
      "mixed-capacity-job",
      "running",
      is_error: false
    )
    job_id = start_content.fetch("job_id")
    cursor = start_content.fetch("cursor")

    busy = exchange(
      stdin,
      stdout,
      run_process_request("mixed-capacity-sync", ["/usr/bin/true"])
    )
    process_structured_content(
      busy,
      "mixed-capacity-sync",
      "execution_busy",
      is_error: true
    )

    read_busy = exchange(
      stdin,
      stdout,
      read_file_request("mixed-capacity-read", "capacity-read.txt")
    )
    tool_structured_content(
      read_busy,
      "mixed-capacity-read",
      "execution_busy",
      is_error: true
    )

    cancel = exchange(
      stdin,
      stdout,
      cancel_process_request("mixed-capacity-cancel", job_id)
    )
    tool_structured_content(
      cancel,
      "mixed-capacity-cancel",
      "cancelling",
      is_error: false
    )

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4.0
    loop do
      terminal = exchange(
        stdin,
        stdout,
        poll_process_request("mixed-capacity-poll", job_id, cursor)
      )
      terminal_status = terminal.dig("result", "structuredContent", "status")
      break if terminal_status == "cancelled"
      raise "mixed-capacity job did not settle" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end

    reused = exchange(
      stdin,
      stdout,
      run_process_request("mixed-capacity-reuse", ["/usr/bin/true"])
    )
    process_structured_content(
      reused,
      "mixed-capacity-reuse",
      "exited",
      is_error: false
    )

    read_reused = exchange(
      stdin,
      stdout,
      read_file_request("mixed-capacity-read-reuse", "capacity-read.txt")
    )
    read_reused_content = tool_structured_content(
      read_reused,
      "mixed-capacity-read-reuse",
      "ok",
      is_error: false
    )
    assert(
      decode_process_stream(read_reused_content.fetch("content")) ==
        "capacity-read".b,
      "read_file did not reuse released shared capacity"
    )
  end

  assert(status.success?, "mixed stdio capacity returned #{status.inspect}")
  assert(stderr.empty?, "mixed stdio capacity wrote to stderr")
end

results << run_case("run_process preserves direct argv and cwd semantics") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|

    exact = exchange(
      stdin,
      stdout,
      run_process_request("exact-name", ["echo"])
    )
    exact_content = process_structured_content(
      exact,
      "exact-name",
      "launch_failed",
      is_error: false
    )
    assert(
      exact_content.key?("launch_stage"),
      "exact_path relative executable did not report launch stage"
    )

    searched = exchange(
      stdin,
      stdout,
      run_process_request(
        "search-name",
        ["echo", "path-search"],
        resolution: "search_path"
      )
    )
    searched_content = process_structured_content(
      searched,
      "search-name",
      "exited",
      is_error: false
    )
    assert(searched_content.fetch("exit_code") == 0, "PATH search exit changed")
    assert(
      decode_process_stream(searched_content.fetch("stdout")) ==
        "path-search\n".b,
      "PATH search did not execute the resolved program"
    )

    literal = "$HOME;printf injected"
    shell_text = exchange(
      stdin,
      stdout,
      run_process_request("literal-argv", ["/bin/echo", literal])
    )
    shell_content = process_structured_content(
      shell_text,
      "literal-argv",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(shell_content.fetch("stdout")) ==
        "#{literal}\n".b,
      "run_process reconstructed argv as implicit shell text"
    )

    empty_argument = exchange(
      stdin,
      stdout,
      run_process_request(
        "empty-argument",
        ["/bin/sh", "-c", "printf '<%s>' \"$1\"", "sonbal-sh", ""]
      )
    )
    empty_content = process_structured_content(
      empty_argument,
      "empty-argument",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(empty_content.fetch("stdout")) == "<>".b,
      "empty nonzero-index argv element was not preserved"
    )

    explicit_cwd = current_workspace_root
    cwd_response = exchange(
      stdin,
      stdout,
      run_process_request(
        "explicit-cwd",
        ["/bin/sh", "-c", "pwd"],
        cwd: explicit_cwd
      )
    )
    cwd_content = process_structured_content(
      cwd_response,
      "explicit-cwd",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(cwd_content.fetch("stdout")) ==
        "#{explicit_cwd}\n".b,
      "child did not observe the explicit working directory"
    )

    relative_cwd = exchange(
      stdin,
      stdout,
      run_process_request(
        "relative-cwd",
        ["/bin/echo", "must-not-run"],
        cwd: "."
      )
    )
    assert(
      relative_cwd == {
        "jsonrpc" => "2.0",
        "id" => "relative-cwd",
        "error" => {"code" => -32602, "message" => "Invalid params"}
      },
      "relative cwd did not fail as invalid params before process creation"
    )
  end

  assert(status.success?, "direct process semantics returned #{status.inspect}")
  assert(stderr.empty?, "direct process semantics wrote to stderr")
end

results << run_case("run_process accepts one aggregate-sized argument") do
  executable_bytes = "/bin/echo".bytesize
  payload = "x" * (32_768 - executable_bytes)

  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    response = exchange(
      stdin,
      stdout,
      run_process_request("large-argv", ["/bin/echo", payload])
    )
    content = process_structured_content(
      response,
      "large-argv",
      "exited",
      is_error: false
    )
    assert(content.fetch("exit_code") == 0, "large argv execution exit changed")
    assert(
      decode_process_stream(content.fetch("stdout")) == "#{payload}\n".b,
      "aggregate-sized argv element was not preserved byte-exactly"
    )
  end

  assert(status.success?, "large argv execution returned #{status.inspect}")
  assert(stderr.empty?, "large argv execution wrote to stderr")
end

results << run_case("run_process owns a minimal child environment") do
  parent_environment = {
    "PATH" => "/m5-parent-path-must-not-leak",
    "HOME" => "/m5-parent-home-must-not-leak",
    "CONTROL_PLANE_API_KEY" => "m5-control-marker",
    "OPENAI_API_KEY" => "m5-openai-marker",
    "OPENAI_ADMIN_KEY" => "m5-admin-marker",
    "SSH_AUTH_SOCK" => "/m5-agent-marker",
    "SONBAL_M5_TEST_MARKER" => "m5-parent-marker"
  }

  _value, stderr, status = run_live_server(
    executable,
    environment: parent_environment
  ) do |stdin, stdout|

    response = exchange(
      stdin,
      stdout,
      run_process_request("environment-exact", ["/usr/bin/env"])
    )
    content = process_structured_content(
      response,
      "environment-exact",
      "exited",
      is_error: false
    )
    assert(content.fetch("exit_code") == 0, "environment probe exit changed")
    assert(
      decode_process_stream(content.fetch("stdout")) ==
        "PATH=#{RUN_PROCESS_PATH}\n".b,
      "child environment was not the exact product-owned environment"
    )

    searched = exchange(
      stdin,
      stdout,
      run_process_request(
        "environment-search",
        ["echo", "product-path"],
        resolution: "search_path"
      )
    )
    searched_content = process_structured_content(
      searched,
      "environment-search",
      "exited",
      is_error: false
    )
    assert(
      searched_content.fetch("exit_code") == 0 &&
        decode_process_stream(searched_content.fetch("stdout")) ==
          "product-path\n".b,
      "search_path did not use the deterministic product PATH"
    )
  end

  assert(status.success?, "environment-policy server returned #{status.inspect}")
  assert(stderr.empty?, "environment-policy server wrote to stderr")
end

results << run_case("run_process preserves streams and completion kinds") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|

    nonzero = exchange(
      stdin,
      stdout,
      run_process_request(
        "nonzero",
        ["/bin/sh", "-c", "printf out; printf err >&2; exit 7"]
      )
    )
    nonzero_content = process_structured_content(
      nonzero,
      "nonzero",
      "exited",
      is_error: false
    )
    assert(nonzero_content.fetch("exit_code") == 7, "nonzero exit code changed")
    assert(
      decode_process_stream(nonzero_content.fetch("stdout")) == "out".b,
      "stdout capture changed"
    )
    assert(
      decode_process_stream(nonzero_content.fetch("stderr")) == "err".b,
      "stderr capture changed"
    )

    signaled = exchange(
      stdin,
      stdout,
      run_process_request(
        "signaled",
        ["/bin/sh", "-c", "kill -KILL $$"]
      )
    )
    signaled_content = process_structured_content(
      signaled,
      "signaled",
      "signaled",
      is_error: false
    )
    assert(
      !signaled_content.key?("exit_code"),
      "signal completion was confused with normal exit"
    )

    missing = exchange(
      stdin,
      stdout,
      run_process_request(
        "launch-failure",
        ["/definitely/not/sonbal-m4-02"]
      )
    )
    missing_content = process_structured_content(
      missing,
      "launch-failure",
      "launch_failed",
      is_error: false
    )
    assert(missing_content.key?("launch_stage"), "launch failure stage was lost")

    exit_127 = exchange(
      stdin,
      stdout,
      run_process_request(
        "exit-127",
        ["/bin/sh", "-c", "exit 127"]
      )
    )
    exit_127_content = process_structured_content(
      exit_127,
      "exit-127",
      "exited",
      is_error: false
    )
    assert(
      exit_127_content.fetch("exit_code") == 127,
      "started process exit 127 was confused with launch failure"
    )
  end

  assert(status.success?, "process outcome matrix returned #{status.inspect}")
  assert(stderr.empty?, "process outcome matrix wrote to stderr")
end

results << run_case("run_process truncates capture without child deadlock") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    exact_response = exchange(
      stdin,
      stdout,
      run_process_request(
        "capture-exact",
        [
          "/bin/sh",
          "-c",
          "dd if=/dev/zero bs=32768 count=1 2>/dev/null"
        ],
        timeout_ms: 5_000
      )
    )
    exact_content = process_structured_content(
      exact_response,
      "capture-exact",
      "exited",
      is_error: false
    )
    exact_stream = exact_content.fetch("stdout")
    exact_capture = decode_process_stream(exact_stream)
    assert(exact_stream.fetch("bytes") == 32_768, "exact capture length changed")
    assert(exact_stream.fetch("truncated") == false, "exact capture was truncated")
    assert(exact_capture.bytes.all?(&:zero?), "exact binary capture was not lossless")

    response = exchange(
      stdin,
      stdout,
      run_process_request(
        "capture-overflow",
        [
          "/bin/sh",
          "-c",
          "dd if=/dev/zero bs=32769 count=1 2>/dev/null"
        ],
        timeout_ms: 5_000
      )
    )
    content = process_structured_content(
      response,
      "capture-overflow",
      "exited",
      is_error: false
    )
    stream = content.fetch("stdout")
    captured = decode_process_stream(stream)
    assert(content.fetch("exit_code") == 0, "overflow producer did not exit zero")
    assert(stream.fetch("bytes") == 32_768, "capture bound was not exact")
    assert(stream.fetch("truncated") == true, "capture overflow was not marked")
    assert(captured.bytes.all?(&:zero?), "binary capture was not lossless")
  end

  assert(status.success?, "capture overflow returned #{status.inspect}")
  assert(stderr.empty?, "capture overflow wrote to stderr")
end

results << run_case("timeout removes the owned descendant tree") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    response = exchange(
      stdin,
      stdout,
      run_process_request(
        "tree-timeout",
        [
          "/bin/sh",
          "-c",
          "sleep 5 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""
        ],
        timeout_ms: 500
      )
    )
    content = process_structured_content(
      response,
      "tree-timeout",
      "timed_out",
      is_error: false
    )
    descendant = Integer(decode_process_stream(content.fetch("stdout")).strip, 10)
    assert(
      wait_process_absent(descendant),
      "timed-out descendant remained alive after completion"
    )
  end

  assert(status.success?, "process-tree timeout returned #{status.inspect}")
  assert(stderr.empty?, "process-tree timeout wrote to stderr")
end

results << run_case("strict ownership contains topology escapes") do
  modes = %w[
    hostile-pgrp
    hostile-setsid
    hostile-double-fork
    hostile-fork-race
  ].freeze

  _value, stderr, status = run_live_server(executable) do |stdin, stdout|

    modes.each_with_index do |mode, index|
      request_id = "strict-tree-#{index}"
      response = exchange(
        stdin,
        stdout,
        run_process_request(
          request_id,
          [process_fixture_executable, mode],
          timeout_ms: 500
        )
      )
      content = process_structured_content(
        response,
        request_id,
        "timed_out",
        is_error: false
      )
      descendant = Integer(
        decode_process_stream(content.fetch("stdout")).strip,
        10
      )
      assert(
        wait_process_absent(descendant),
        "#{mode} descendant remained alive after timeout completion"
      )
    end
  end

  assert(status.success?, "strict tree execution returned #{status.inspect}")
  assert(stderr.empty?, "strict tree execution wrote to stderr")
end


results << run_case("strict ownership outlives closed captured streams") do
  Dir.mktmpdir("sonbal-strict-streams") do |directory|
    pid_path = File.join(directory, "descendant.pid")

    _value, stderr, status = run_live_server(executable) do |stdin, stdout|
      command = [
        "/bin/sh",
        "-c",
        'exec "$1" hostile-daemon > "$2" 2>/dev/null',
        "sonbal-strict-streams",
        process_fixture_executable,
        pid_path
      ]
      response = exchange(
        stdin,
        stdout,
        run_process_request(
          "strict-streams",
          command,
          timeout_ms: 500
        )
      )
      content = process_structured_content(
        response,
        "strict-streams",
        "execution_failed",
        is_error: true
      )
      assert(
        content.fetch("infrastructure_stage") == "process_termination",
        "closed-stream daemon did not report process_termination failure"
      )
      assert(
        decode_process_stream(content.fetch("stdout")).empty?,
        "redirected hostile daemon unexpectedly retained captured stdout"
      )
      descendant = Integer(File.read(pid_path, encoding: "UTF-8").strip, 10)
      assert(
        wait_process_absent(descendant),
        "closed-stream daemon remained alive after timeout completion"
      )
    end

    assert(status.success?, "closed-stream strict execution failed")
    assert(stderr.empty?, "closed-stream strict execution wrote to stderr")
  end
end


results << run_case("strict ownership cleans detached output drain") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    response = exchange(
      stdin,
      stdout,
      run_process_request(
        "strict-drain",
        [process_fixture_executable, "hostile-daemon"],
        timeout_ms: 5_000
      )
    )
    content = process_structured_content(
      response,
      "strict-drain",
      "execution_failed",
      is_error: true
    )
    assert(
      content.fetch("infrastructure_stage") == "output_drain",
      "detached descendant did not report output_drain failure"
    )
    descendant = Integer(
      decode_process_stream(content.fetch("stdout")).strip,
      10
    )
    assert(
      wait_process_absent(descendant),
      "detached output-drain descendant remained alive"
    )
  end

  assert(status.success?, "strict drain execution returned #{status.inspect}")
  assert(stderr.empty?, "strict drain execution wrote to stderr")
end


results << run_case("output drain failure is explicit and cleans descendants") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    response = exchange(
      stdin,
      stdout,
      run_process_request(
        "drain-failure",
        ["/bin/sh", "-c", "(trap '' HUP; sleep 5) & printf '%s\\n' \"$!\""]
      )
    )
    content = process_structured_content(
      response,
      "drain-failure",
      "execution_failed",
      is_error: true
    )
    assert(
      content.fetch("infrastructure_stage") == "output_drain",
      "open descendant stream did not report output_drain failure"
    )
    descendant = Integer(decode_process_stream(content.fetch("stdout")).strip, 10)
    assert(
      wait_process_absent(descendant),
      "output-drain cleanup left the descendant alive"
    )
  end

  assert(status.success?, "output-drain failure returned #{status.inspect}")
  assert(stderr.empty?, "output-drain failure wrote to stderr")
end

results << run_case("concurrent executions avoid head-of-line blocking") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    slow = run_process_request(
      "overlap-slow",
      ["/bin/sh", "-c", "sleep 1; printf slow"],
      timeout_ms: 5_000
    )
    fast = run_process_request(
      "overlap-fast",
      ["/bin/echo", "fast"]
    )

    stdin.write(slow)
    stdin.write("\n")
    stdin.write(fast)
    stdin.write("\n")
    stdin.flush

    first = JSON.parse(stdout.gets || raise("missing fast response"))
    fast_content = process_structured_content(
      first,
      "overlap-fast",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(fast_content.fetch("stdout")) == "fast\n".b,
      "concurrent fast execution did not complete first"
    )

    second = JSON.parse(stdout.gets || raise("missing slow response"))
    slow_content = process_structured_content(
      second,
      "overlap-slow",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(slow_content.fetch("stdout")) == "slow".b,
      "concurrent slow execution did not complete"
    )
  end

  assert(
    status.success?,
    "concurrent execution overlap returned #{status.inspect}"
  )
  assert(stderr.empty?, "concurrent execution overlap wrote to stderr")
end

results << run_case("independent requests avoid head-of-line blocking") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|

    slow = run_process_request(
      "hol-slow",
      ["/bin/sh", "-c", "sleep 1; printf slow"],
      timeout_ms: 5_000
    )
    fast = run_process_request(
      "fast",
      ["/bin/echo", "fast"]
    ).sub(%q("id":"fast"), %q("id":"\u0066ast"))

    stdin.write(slow)
    stdin.write("\n")
    stdin.write(fast)
    stdin.write("\n")
    stdin.flush

    fast_line = stdout.gets
    raise "missing independent fast response" if fast_line.nil?
    assert(
      fast_line.include?(%q("id":"\u0066ast")),
      "out-of-order completion changed request-id spelling"
    )
    fast_response = JSON.parse(fast_line)
    fast_content = process_structured_content(
      fast_response,
      "fast",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(fast_content.fetch("stdout")) == "fast\n".b,
      "independent fast process output changed"
    )

    slow_response = JSON.parse(stdout.gets || raise("missing slow HOL response"))
    slow_content = process_structured_content(
      slow_response,
      "hol-slow",
      "exited",
      is_error: false
    )
    assert(
      decode_process_stream(slow_content.fetch("stdout")) == "slow".b,
      "slow independent process did not complete"
    )
  end

  assert(
    status.success?,
    "independent request execution returned #{status.inspect}"
  )
  assert(stderr.empty?, "independent request execution wrote to stderr")
end

results << run_case("fatal local failure cancels pending run_process") do
  pid_path = "/tmp/sonbal-m4-02-fatal-#{Process.pid}.pid"
  File.delete(pid_path) if File.exist?(pid_path)
  descendant = nil

  output, stderr, status = run_live_server(executable) do |stdin, stdout|
    command =
      "(trap '' HUP; sleep 5) & child=$!; " \
      "printf '%s\\n' \"$child\" > #{pid_path}; wait \"$child\""
    stdin.write(
      run_process_request(
        "fatal-process",
        ["/bin/sh", "-c", command],
        timeout_ms: 10_000
      )
    )
    stdin.write("\n")
    stdin.flush

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    until File.file?(pid_path)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise "pending process did not publish its descendant pid"
      end
      sleep 0.02
    end
    descendant = Integer(File.read(pid_path, encoding: "UTF-8").strip, 10)

    stdin.write("{")
    stdin.flush
    close_io(stdin)
    stdout.read
  end

  assert_failed_exit(status, "fatal local failure with pending run_process")
  assert(output.empty?, "fatal failure fabricated a process response")
  assert(
    stderr.empty?,
    "fatal process cleanup wrote to stderr instead of native diagnostics"
  )
  assert(
    !descendant.nil? && wait_process_absent(descendant),
    "fatal local failure left an owned descendant alive"
  )
ensure
  File.delete(pid_path) if File.exist?(pid_path)
end

results << run_case("EOF cancellation removes topology escape") do
  Dir.mktmpdir("sonbal-strict-eof") do |directory|
    pid_path = File.join(directory, "descendant.pid")
    descendant = nil

    output, stderr, status = run_live_server(executable) do |stdin, stdout|
      command = [
        "/bin/sh",
        "-c",
        'exec "$1" hostile-setsid > "$2"',
        "sonbal-strict-eof",
        process_fixture_executable,
        pid_path
      ]
      stdin.write(
        run_process_request(
          "strict-eof-process",
          command,
          timeout_ms: 100_000
        )
      )
      stdin.write("\n")
      stdin.flush

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
      loop do
        if File.file?(pid_path) && !File.zero?(pid_path)
          descendant = Integer(
            File.read(pid_path, encoding: "UTF-8").strip,
            10
          )
          break
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "topology-escaping descendant did not publish its pid"
        end
        sleep 0.02
      end

      close_io(stdin)
      stdout.read
    end

    assert(
      status.success?,
      "strict EOF cancellation returned #{status.inspect}"
    )
    assert(output.empty?, "strict EOF cancellation fabricated a response")
    assert(stderr.empty?, "strict EOF cancellation wrote to stderr")
    assert(
      !descendant.nil? && wait_process_absent(descendant),
      "EOF cancellation left a topology-escaping descendant alive"
    )
  end
end


results << run_case("pending run_process cancels on EOF") do
  output, stderr, status = run_live_server(executable) do |stdin, stdout|
    stdin.write(
      run_process_request(
        "cancel-process",
        ["/bin/sleep", "60"],
        timeout_ms: 100_000
      )
    )
    stdin.write("\n")
    stdin.flush
    close_io(stdin)
    stdout.read
  end

  assert(status.success?, "run_process EOF cleanup returned #{status.inspect}")
  assert(output.empty?, "EOF cancellation fabricated a process response")
  assert(stderr.empty?, "run_process EOF cleanup wrote to stderr")
end

results << run_case("EOF cancellation uses an absolute settle deadline") do
  Dir.mktmpdir("sonbal-stdio-settle") do |directory|
    pid_path = File.join(directory, "child.pid")
    child_pid = nil

    output, stderr, status = run_live_server(executable) do |stdin, stdout|
      command =
        "printf '%d\\n' $$ > #{pid_path}; " \
        "trap '' TERM; while :; do printf x; done"
      stdin.write(
        run_process_request(
          "absolute-settle-deadline",
          ["/bin/sh", "-c", command],
          timeout_ms: 100_000
        )
      )
      stdin.write("\n")
      stdin.flush

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
      until File.file?(pid_path) && !File.zero?(pid_path)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "settle-deadline child did not publish its pid"
        end
        sleep 0.01
      end
      child_pid = Integer(File.read(pid_path, encoding: "UTF-8").strip, 10)

      close_io(stdin)
      stdout.read
    end

    assert(status.success?, "absolute settle cleanup returned #{status.inspect}")
    assert(output.empty?, "absolute settle cleanup fabricated a response")
    assert(stderr.empty?, "absolute settle cleanup wrote to stderr")
    assert(
      !child_pid.nil? && wait_process_absent(child_pid),
      "absolute settle cleanup left SIGTERM-resistant output producer alive"
    )
  end
end

results << run_case("broken stdout cancels pending run_process") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    stdin.write(
      run_process_request(
        "broken-process",
        ["/bin/sleep", "60"],
        timeout_ms: 100_000
      )
    )
    stdin.write("\n")
    stdin.flush
    close_io(stdout)
    stdin.write(PING_OPEN_REQUEST)
    stdin.write("\n")
    stdin.flush
  end

  assert_failed_exit(status, "broken stdout with pending run_process")
  assert(!status.signaled?, "broken process stdout escaped through SIGPIPE")
  assert(
    stderr.empty?,
    "broken process stdout cleanup wrote to stderr instead of native diagnostics"
  )
end

results << run_case("unknown tools and arguments are rejected") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    unknown_tool = exchange(
      stdin,
      stdout,
      tool_request(100, "unknown_tool")
    )
    assert(
      unknown_tool == {
        "jsonrpc" => "2.0",
        "id" => 100,
        "error" => {"code" => -32602, "message" => "Invalid params"}
      },
      "unknown tool name was not rejected"
    )

    unknown_argument = exchange(
      stdin,
      stdout,
      tool_request(
        101,
        "run_process",
        "workspace_token" => current_workspace_token,
        "argv" => ["/usr/bin/true"],
        "resolution" => "exact_path",
        "cwd" => current_workspace_root,
        "timeout_ms" => 1_000,
        "unexpected" => 1
      )
    )
    assert(
      unknown_argument == {
        "jsonrpc" => "2.0",
        "id" => 101,
        "error" => {"code" => -32602, "message" => "Invalid params"}
      },
      "unknown run_process argument was not rejected"
    )
  end

  assert(status.success?, "unknown-input rejection returned #{status.inspect}")
  assert(stderr.empty?, "unknown-input rejection wrote to stderr")
end

results << run_case("bounded stdout backpressure preserves complete frames") do
  request_count = 32
  request_ids = request_count.times.map { |index| "backpressure-#{index}" }
  requests = request_ids.map do |id|
    TOOLS_LIST_REQUEST.sub(%q("id":2), %Q("id":"#{id}"))
  end
  input = requests.join("\n") + "\n"

  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    stdin.write(input)
    stdin.flush

    responses = request_count.times.map do
      line = stdout.gets
      raise "server closed stdout during backpressure acceptance" if line.nil?

      JSON.parse(line)
    end

    response_ids = responses.map { |response| response.fetch("id") }
    assert(
      response_ids.sort == request_ids.sort,
      "backpressured stdout lost, duplicated, or corrupted response ids"
    )

    responses.each do |response|
      tool_names = response.dig("result", "tools")&.map { |tool| tool["name"] }
      assert(
        tool_names == EXPECTED_TOOL_NAMES,
        "backpressured stdout emitted an incomplete or interleaved frame"
      )
    end
  end

  assert(status.success?, "stdout backpressure returned #{status.inspect}")
  assert(stderr.empty?, "stdout backpressure wrote to stderr")
end

results << run_case("bounded parser rejection preserves stdio correlation") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    bounded_request = JSON.generate(
      "jsonrpc" => "2.0",
      "id" => "bounded-policy",
      "method" => "x" * (MAX_GENERIC_JSON_TEXT_BYTES + 1),
      "params" => {}
    )

    rejected = exchange(stdin, stdout, bounded_request)
    assert(
      rejected == {
        "jsonrpc" => "2.0",
        "id" => "bounded-policy",
        "error" => {"code" => -32600, "message" => "Invalid Request"}
      },
      "bounded parser rejection lost JSON-RPC request correlation"
    )

    ping = exchange(stdin, stdout, PING_OPEN_REQUEST)
    assert(
      ping == JSON.parse(PING_OPEN_RESPONSE),
      "bounded parser rejection did not preserve the stdio connection"
    )
  end

  assert(status.success?, "bounded parser rejection returned #{status.inspect}")
  assert(stderr.empty?, "bounded parser rejection wrote to stderr")
end

results << run_case("large unknown params remain request local") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    bounded_request = JSON.generate(
      "jsonrpc" => "2.0",
      "id" => "bounded-policy",
      "method" => "tools/call",
      "params" => {
        "padding" => "x" * (MAX_GENERIC_JSON_TEXT_BYTES + 1)
      }
    )

    rejected = exchange(stdin, stdout, bounded_request)
    assert(
      rejected == {
        "jsonrpc" => "2.0",
        "id" => "bounded-policy",
        "error" => {"code" => -32602, "message" => "Invalid params"}
      },
      "large unknown params escaped request-local invalid-param handling"
    )

    ping = exchange(stdin, stdout, PING_OPEN_REQUEST)
    assert(
      ping == JSON.parse(PING_OPEN_RESPONSE),
      "large unknown params did not preserve the stdio connection"
    )
  end

  assert(status.success?, "large unknown params returned #{status.inspect}")
  assert(stderr.empty?, "large unknown params wrote to stderr")
end

results << run_case("clean EOF") do
  stdout, stderr, status = run_server(executable, "")
  assert(status.success?, "clean EOF returned #{status.inspect}")
  assert(stdout.empty?, "clean EOF wrote protocol output")
  assert(stderr.empty?, "clean EOF wrote a diagnostic")
end

results << run_case("truncated EOF") do
  stdout, stderr, status = run_server(executable, "{")
  assert_failed_exit(status, "truncated EOF")
  assert(stdout.empty?, "truncated EOF wrote protocol output")
  assert(
    stderr.empty?,
    "truncated EOF wrote to stderr instead of native diagnostics"
  )
end

results << run_case("oversized frame is request local") do
  _value, stderr, status = run_live_server(executable) do |stdin, stdout|
    stdin.write("x" * (MAX_MESSAGE_BYTES + 1))
    stdin.write("\n")
    stdin.flush

    ping = exchange(stdin, stdout, PING_OPEN_REQUEST)
    assert(
      ping == JSON.parse(PING_OPEN_RESPONSE),
      "oversized frame prevented the following request from completing"
    )
  end

  assert(status.success?, "oversized frame returned #{status.inspect}")
  assert(stderr.empty?, "oversized frame wrote to stderr")
end

results << run_case("broken stdout") do
  input = DISCOVER_REQUEST + "\n"
  stdout, stderr, status =
    run_server(executable, input, close_stdout_reader: true)
  assert_failed_exit(status, "broken stdout")
  assert(!status.signaled?, "broken stdout escaped through SIGPIPE")
  assert(stdout.empty?, "broken stdout unexpectedly captured output")
  assert(
    stderr.empty?,
    "broken stdout wrote to stderr instead of native diagnostics"
  )
end

passed = results.count(true)
if results.all?
  puts "Integration: [SUCCESS] #{passed} cases passed."
  exit 0
end

warn "Integration: [FAILURE] #{passed}/#{results.length} cases passed."
exit 1
