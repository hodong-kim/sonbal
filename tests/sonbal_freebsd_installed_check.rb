#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_freebsd_installed_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "etc"
require "json"
require "open3"
require "tmpdir"

artifact = File.expand_path(ARGV.fetch(0))
pkg = ENV.fetch("PKG", "/usr/local/sbin/pkg")
ps = ENV.fetch("PS", "/bin/ps")
daemon = ENV.fetch("DAEMON", "/usr/sbin/daemon")
tmp_root = Dir.tmpdir

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  fail!("#{command.join(' ')}: #{stderr.strip}") unless status.success?
  stdout
end

def process_rows(ps)
  capture!(
    ps, "axww",
    "-o", "pid=",
    "-o", "ppid=",
    "-o", "user=",
    "-o", "group=",
    "-o", "tty=",
    "-o", "comm=",
    "-o", "args="
  ).lines.filter_map do |line|
    fields = line.strip.split(/\s+/, 7)
    fields if fields.length == 7
  end
end

def assert_file(path)
  fail!("missing installed file: #{path}") unless File.file?(path)
end

def reject_path(path)
  fail!("retired installed path remains: #{path}") if
    File.exist?(path) || File.symlink?(path)
end

def assert_mode(path, expected)
  actual = File.stat(path).mode & 0o7777
  fail!("unexpected mode for #{path}: %04o" % actual) unless actual == expected
end

def monotonic_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def pid_from_file(path)
  text = File.read(path).strip
  return nil unless text.match?(/\A[1-9][0-9]*\z/)

  Integer(text, 10)
rescue Errno::ENOENT
  nil
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

def terminate_detached(supervisor_pidfile, child_pidfile)
  supervisor_pid = pid_from_file(supervisor_pidfile)
  child_pid = pid_from_file(child_pidfile)
  return if supervisor_pid.nil? && child_pid.nil?

  signal_pid = supervisor_pid || child_pid
  Process.kill("TERM", signal_pid) if process_alive?(signal_pid)

  pids = [child_pid, supervisor_pid].compact.uniq
  deadline = monotonic_now + 1.0
  while pids.any? { |pid| process_alive?(pid) } && monotonic_now < deadline
    sleep 0.01
  end

  pids.each do |pid|
    Process.kill("KILL", pid) if process_alive?(pid)
  rescue Errno::ESRCH
    nil
  end
end

fail!("installed check must not run as root") if Process.euid.zero?
fail!("FreeBSD package artifact not found: #{artifact}") unless File.file?(artifact)

raw = capture!(pkg, "info", "-F", artifact, "-R", "--raw-format", "json")
manifest = JSON.parse(raw)
manifest = manifest.first if manifest.is_a?(Array)
expected_version = manifest.fetch("version")
artifact_deps = manifest.fetch("deps")
fail!("artifact must declare exactly one curl dependency") unless
  artifact_deps.is_a?(Hash) && artifact_deps.length == 1
curl_name, curl_metadata = artifact_deps.first
fail!("artifact curl dependency name changed") unless curl_name == "curl"
fail!("artifact curl dependency origin changed") unless
  curl_metadata.fetch("origin") == "ftp/curl"

installed_curl = capture!(pkg, "query", "%n\t%o\t%v", curl_name).strip
curl_fields = installed_curl.split("\t", -1)
fail!("installed curl dependency metadata is malformed") unless
  curl_fields.length == 3 && curl_fields.none?(&:empty?)
fail!("installed curl package identity changed") unless
  curl_fields.fetch(0) == curl_name &&
    curl_fields.fetch(1) == curl_metadata.fetch("origin") &&
    curl_fields.fetch(2) == curl_metadata.fetch("version")

installed_version = capture!(pkg, "query", "%v", "sonbal").strip
unless installed_version == expected_version
  fail!(
    "installed Sonbal version #{installed_version.inspect} differs from " \
      "artifact #{expected_version.inspect}; install the exact artifact first"
  )
end
capture!(pkg, "check", "-s", "sonbal")

Dir.mktmpdir("sonbal-freebsd-installed-", tmp_root) do |dir|
  capture!("/usr/bin/tar", "-xf", artifact, "-C", dir)
  packaged_revisions = File.read(
    File.join(dir, "usr", "local", "share", "sonbal", "package-revisions")
  )
  installed_revisions = File.read("/usr/local/share/sonbal/package-revisions")
  unless installed_revisions == packaged_revisions
    fail!(
      "installed revision metadata differs from package artifact; " \
        "force-install the exact artifact before rerunning acceptance"
    )
  end
end

%w[
  /usr/local/bin/sonbal
  /usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so
  /usr/local/etc/sonbal/sonbal.yaml.sample
  /usr/local/etc/sonbal/sonbal.yaml
  /usr/local/etc/sonbal/openai.json.sample
  /usr/local/etc/sonbal/openai.json
  /usr/local/etc/rc.d/sonbal_openai
  /usr/local/share/sonbal/package-revisions
].each { |path| assert_file(path) }

%w[
  /usr/local/etc/rc.d/sonbal_fastcgi
  /usr/local/etc/rc.d/sonbal_tunnel
  /usr/local/etc/nginx/conf.d/sonbal.conf.sample
  /usr/local/etc/nginx/conf.d/sonbal.conf
  /usr/local/share/sonbal/sonbal-fastcgi.inetd
  /var/run/sonbal-fastcgi.sock
  /var/run/sonbal-mcp/http.sock
].each { |path| reject_path(path) }

fail!("active Sonbal configuration differs from package sample") unless
  File.read("/usr/local/etc/sonbal/sonbal.yaml") ==
    File.read("/usr/local/etc/sonbal/sonbal.yaml.sample")

openai_config = File.read("/usr/local/etc/sonbal/openai.json")
begin
  parsed_openai_config = JSON.parse(openai_config)
rescue JSON::ParserError => error
  fail!("installed OpenAI config is invalid JSON: #{error.message}")
end
fail!("installed OpenAI config is not an object") unless
  parsed_openai_config.is_a?(Hash)
fail!("installed OpenAI config gained secret-bearing state") if
  openai_config.match?(/credential|api[_-]?key|secret/i)

assert_mode("/usr/local/bin/sonbal", 0o555)
assert_mode(
  "/usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so", 0o555
)
assert_mode("/usr/local/etc/rc.d/sonbal_openai", 0o555)
assert_mode("/usr/local/etc/sonbal/sonbal.yaml", 0o644)
assert_mode("/usr/local/etc/sonbal/openai.json", 0o644)

execution = Etc.getpwnam("sonbal")
execution_group = Etc.getgrnam("sonbal")
fail!("execution identity unexpectedly resolves to root") if execution.uid.zero?
fail!("execution identity primary group is not sonbal") unless
  execution.gid == execution_group.gid
fail!("sonbal is not a non-login identity") unless execution.shell.end_with?("nologin")
fail!("installed check must run as the sonbal execution identity") unless
  Process.euid == execution.uid

rows = process_rows(ps)
openai_rows = rows.select do |row|
  row[2] == "sonbal" && row[5] == "sonbal" &&
    row[6] == "/usr/local/bin/sonbal --connector openai"
end
fail!("OpenAI service must be stopped for installed-state acceptance") unless
  openai_rows.empty?

retired_processes = rows.select do |row|
  row[6] == "sonbal --fastcgi" ||
    row[6].include?("/usr/local/share/sonbal/sonbal-fastcgi.inetd") ||
    (row[5] == "tunnel-client" &&
      row[6].include?("/var/db/sonbal-tunnel/"))
end
fail!("retired ingress process remains: #{retired_processes.inspect}") unless
  retired_processes.empty?

openai_state = "/var/db/sonbal-openai"
if File.directory?(openai_state)
  wheel = Etc.getgrnam("wheel")
  openai_dir = File.stat(openai_state)
  fail!("unexpected OpenAI state owner") unless openai_dir.uid.zero?
  fail!("unexpected OpenAI state group") unless openai_dir.gid == wheel.gid
  assert_mode(openai_state, 0o700)

  credential = File.join(openai_state, "credential")
  if File.exist?(credential)
    credential_stat = File.stat(credential)
    fail!("OpenAI credential owner changed") unless credential_stat.uid.zero?
    fail!("OpenAI credential group changed") unless
      credential_stat.gid == wheel.gid
    assert_mode(credential, 0o600)

    begin
      File.open(credential, File::RDONLY) { |_file| }
      fail!("sonbal execution identity can read the OpenAI credential")
    rescue Errno::EACCES
      nil
    end
  end
end

Dir.mktmpdir("sonbal-freebsd-security-", tmp_root) do |dir|
  output = File.join(dir, "security-check.out")
  supervisor_pidfile = File.join(dir, "daemon.pid")
  child_pidfile = File.join(dir, "child.pid")

  capture!(
    daemon, "-f", "-o", output, "-M", "600",
    "-P", supervisor_pidfile, "-p", child_pidfile,
    "/usr/bin/env", "-i", "PATH=/usr/local/bin:/usr/bin:/bin",
    "/usr/local/bin/sonbal", "--security-check"
  )

  result_deadline = monotonic_now + 5.0
  security = ""
  loop do
    security = File.read(output) if File.file?(output)
    break if security.lines.any? { |line| line.start_with?("result=") }
    if monotonic_now >= result_deadline
      terminate_detached(supervisor_pidfile, child_pidfile)
      fail!("detached installed Sonbal security preflight did not finish")
    end
    sleep 0.01
  end

  settle_deadline = monotonic_now + 1.0
  while File.exist?(supervisor_pidfile) || File.exist?(child_pidfile)
    if monotonic_now >= settle_deadline
      terminate_detached(supervisor_pidfile, child_pidfile)
      fail!("detached installed Sonbal security preflight did not settle")
    end
    sleep 0.01
  end

  fail!("installed Sonbal security preflight is not hardened") unless
    security.lines.any? { |line| line.strip == "result=hardened" }
end

puts "[PASS] installed FreeBSD connector-only package state"
