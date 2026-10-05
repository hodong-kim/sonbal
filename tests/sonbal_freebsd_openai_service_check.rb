#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_freebsd_openai_service_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "etc"
require "json"
require "open3"
require "rbconfig"

expected_state = ARGV.fetch(0)
unless %w[running stopped].include?(expected_state)
  warn "[FAIL] expected state must be running or stopped"
  exit 1
end

ps = ENV.fetch("PS", "/bin/ps")
procstat = ENV.fetch("PROCSTAT", "/usr/bin/procstat")

state_dir = "/var/db/sonbal-openai"
credential = File.join(state_dir, "credential")
configuration = "/usr/local/etc/sonbal/openai.json"
supervisor_pidfile = "/var/run/sonbal-openai-supervisor.pid"
child_pidfile = "/var/run/sonbal-openai.pid"
sonbal_binary = "/usr/local/bin/sonbal"
daemon_binary = "/usr/sbin/daemon"
expected_args = "#{sonbal_binary} --connector openai"


def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end


def capture(*command)
  Open3.capture3(*command)
end


def capture!(command, *arguments)
  stdout, stderr, status = capture(command, *arguments)
  fail!("#{([command] + arguments).join(' ')}: #{stderr.strip}") unless
    status.success?
  stdout
end


def numeric_groups!(identity)
  capture!("/usr/bin/id", "-G", identity).split.map do |item|
    Integer(item, 10)
  end
rescue ArgumentError
  fail!("invalid numeric group list for #{identity}")
end


def assert_mode(path, expected)
  actual = File.stat(path).mode & 0o7777
  return if actual == expected

  fail!("unexpected mode for #{path}: %04o" % actual)
end


def assert_root_pidfile(path, wheel_gid)
  stat = File.lstat(path)
  fail!("service pidfile is a symlink: #{path}") if stat.symlink?
  fail!("service pidfile is not a regular file: #{path}") unless stat.file?
  fail!("service pidfile is not root-owned: #{path}") unless stat.uid.zero?
  fail!("service pidfile group changed: #{path}") unless stat.gid == wheel_gid
  assert_mode(path, 0o600)

  begin
    File.open(path, File::RDONLY) { |_file| }
    fail!("non-root checker can read root-only service pidfile: #{path}")
  rescue Errno::EACCES
    nil
  end
rescue Errno::ENOENT
  fail!("missing service pidfile: #{path}")
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


def descendant_of?(row, ancestor_pid, rows_by_pid)
  current = row
  visited = {}

  loop do
    pid = Integer(current.fetch(0), 10)
    return true if pid == ancestor_pid
    return false if pid <= 1 || visited[pid]

    visited[pid] = true
    parent_pid = Integer(current.fetch(1), 10)
    current = rows_by_pid[parent_pid]
    return false if current.nil?
  end
rescue ArgumentError
  false
end


def assert_binary(procstat, pid, expected)
  output = capture!(procstat, "-b", pid.to_s)
  return if output.lines.any? do |line|
    line.strip.split(/\s+/, 4).last == expected
  end

  fail!("pid #{pid} executable changed")
end


fail!("OpenAI service check must run on FreeBSD") unless
  RbConfig::CONFIG.fetch("host_os").include?("freebsd")
sonbal = Etc.getpwnam("sonbal")
fail!("OpenAI service check must run as the sonbal execution identity") unless
  Process.euid == sonbal.uid

sonbal_group = Etc.getgrnam("sonbal")
wheel = Etc.getgrnam("wheel")
fail!("sonbal execution identity unexpectedly has uid 0") if sonbal.uid.zero?
fail!("sonbal execution primary group changed") unless
  sonbal.gid == sonbal_group.gid
fail!("sonbal execution identity belongs to wheel") if
  numeric_groups!("sonbal").include?(wheel.gid)

fail!("missing installed OpenAI config") unless File.file?(configuration)
config_text = File.read(configuration, encoding: "UTF-8")
begin
  parsed_config = JSON.parse(config_text)
rescue JSON::ParserError => error
  fail!("installed OpenAI config is invalid JSON: #{error.message}")
end
fail!("installed OpenAI config is not an object") unless
  parsed_config.is_a?(Hash)
fail!("installed OpenAI config gained secret-bearing state") if
  config_text.match?(/credential|api[_-]?key|secret/i)

tunnel_id = parsed_config["tunnel_id"]
fail!("OpenAI service acceptance requires a non-empty tunnel_id") unless
  tunnel_id.is_a?(String) && !tunnel_id.empty?

fail!("missing OpenAI credential state directory") unless
  File.directory?(state_dir)
dir_stat = File.stat(state_dir)
fail!("OpenAI state directory is not root-owned") unless dir_stat.uid.zero?
fail!("OpenAI state directory group changed") unless dir_stat.gid == wheel.gid
assert_mode(state_dir, 0o700)

begin
  secret = File.open(credential, File::RDONLY)
  secret.close
  fail!("non-root checker can read the OpenAI credential")
rescue Errno::EACCES
  # Expected: root:wheel 0700 state blocks pathname traversal.
rescue Errno::ENOENT
  fail!("OpenAI credential is missing or hidden behind an unexpected path")
end

rows = process_rows(ps)
rows_by_pid = rows.to_h { |row| [Integer(row.fetch(0), 10), row] }
candidate_rows = rows.select do |row|
  row[2] == "sonbal" && row[6].include?("--connector openai")
end
openai_rows = candidate_rows.select do |row|
  row[3] == "sonbal" && row[5] == "sonbal" &&
    row[6] == expected_args
end

if expected_state == "stopped"
  fail!("stopped OpenAI service still has a candidate Sonbal child") unless
    candidate_rows.empty?
  fail!("stopped OpenAI service retained supervisor pidfile") if
    File.exist?(supervisor_pidfile)
  fail!("stopped OpenAI service retained child pidfile") if
    File.exist?(child_pidfile)

  puts "[PASS] FreeBSD OpenAI service stopped and settled"
  exit 0
end

service_roots = openai_rows.select do |row|
  parent = rows_by_pid[Integer(row.fetch(1), 10)]
  !parent.nil? &&
    parent[1].to_i == 1 &&
    parent[2] == "root" &&
    parent[3] == "wheel" &&
    parent[4] == "-" &&
    parent[5] == "daemon"
end
fail!("expected exactly one OpenAI service root") unless
  service_roots.length == 1

child = service_roots.fetch(0)
child_pid = Integer(child[0], 10)
child_ppid = Integer(child[1], 10)
foreign_candidates = candidate_rows.reject do |row|
  descendant_of?(row, child_pid, rows_by_pid)
end
fail!("independent OpenAI Sonbal process remains") unless
  foreign_candidates.empty?

fail!("OpenAI Sonbal child has a controlling terminal") unless child[4] == "-"
assert_binary(procstat, child_pid, sonbal_binary)

supervisor = rows_by_pid[child_ppid]
fail!("OpenAI daemon supervisor is missing") if supervisor.nil?
fail!("OpenAI supervisor is not root-owned daemon(8)") unless
  supervisor[2] == "root" && supervisor[3] == "wheel" &&
    supervisor[5] == "daemon"
fail!("OpenAI supervisor has a controlling terminal") unless
  supervisor[4] == "-"
fail!("OpenAI supervisor is not an independent service") unless
  supervisor[1].to_i == 1
assert_binary(procstat, child_ppid, daemon_binary)

# daemon(8) creates these service-control files as root:wheel 0600.
# The non-root acceptance checker must prove that boundary without weakening it
# or depending on read access to root-owned PID contents. Process identity and
# parentage above independently establish the running topology.
assert_root_pidfile(supervisor_pidfile, wheel.gid)
assert_root_pidfile(child_pidfile, wheel.gid)

sleep 0.25
second_rows = process_rows(ps)
second_rows_by_pid =
  second_rows.to_h { |row| [Integer(row.fetch(0), 10), row] }
stable_child = second_rows_by_pid[child_pid]
stable_supervisor = second_rows_by_pid[child_ppid]
unless stable_child &&
       stable_child[1].to_i == child_ppid &&
       stable_child[2] == "sonbal" &&
       stable_child[3] == "sonbal" &&
       stable_child[4] == "-" &&
       stable_child[5] == "sonbal" &&
       stable_child[6] == expected_args
  fail!("OpenAI service process identity changed during stability probe")
end
unless stable_supervisor &&
       stable_supervisor[1].to_i == 1 &&
       stable_supervisor[2] == "root" &&
       stable_supervisor[3] == "wheel" &&
       stable_supervisor[4] == "-" &&
       stable_supervisor[5] == "daemon"
  fail!("OpenAI daemon supervisor changed during stability probe")
end
assert_root_pidfile(supervisor_pidfile, wheel.gid)
assert_root_pidfile(child_pidfile, wheel.gid)

puts "[PASS] FreeBSD OpenAI service running with isolated credential boundary"
