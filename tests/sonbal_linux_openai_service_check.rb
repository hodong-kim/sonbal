#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_linux_openai_service_check.rb
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

systemctl = ENV.fetch("SYSTEMCTL", "/usr/bin/systemctl")
ps = ENV.fetch("PS", "/usr/bin/ps")

state_dir = "/var/lib/sonbal-openai"
credential = File.join(state_dir, "credential")
configuration = "/etc/sonbal/openai.json"
sonbal_binary = "/usr/bin/sonbal"
unit = "sonbal-openai.service"
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


def properties(systemctl, unit, names)
  output = capture!(
    systemctl, "show", unit,
    *names.flat_map { |name| ["-p", name] }
  )
  output.lines.to_h do |line|
    name, value = line.chomp.split("=", 2)
    [name, value || ""]
  end
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
  pid = Integer(row[0], 10)
  visited = {}

  loop do
    return true if pid == ancestor_pid
    return false if pid <= 1 || visited[pid]

    visited[pid] = true
    current = rows_by_pid[pid]
    return false if current.nil?

    pid = Integer(current[1], 10)
  end
end


def service_cgroup_path!(pid)
  lines = File.readlines("/proc/#{pid}/cgroup", chomp: true)
  unified = lines.select { |line| line.start_with?("0::/") }
  fail!("OpenAI service is not in one unified cgroup v2 hierarchy") unless
    unified.length == 1

  "/sys/fs/cgroup#{unified.fetch(0).delete_prefix("0::")}"
rescue SystemCallError => error
  fail!("cannot inspect OpenAI service cgroup: #{error.class}")
end


def verify_strict_ownership_delegation!(service_pid, identity_uid, identity_gid)
  parent = service_cgroup_path!(service_pid)
  parent_stat = File.stat(parent)
  unless parent_stat.uid == identity_uid && parent_stat.gid == identity_gid
    fail!("OpenAI service cgroup delegation owner changed")
  end
  unless (parent_stat.mode & 0o700) == 0o700
    fail!("OpenAI service cgroup delegation root is not owner-manageable")
  end

  %w[cgroup.procs cgroup.threads cgroup.subtree_control].each do |name|
    path = File.join(parent, name)
    stat = File.stat(path)
    unless stat.uid == identity_uid && stat.gid == identity_gid
      fail!("OpenAI service delegated cgroup file owner changed: #{name}")
    end
    fail!("OpenAI service delegated cgroup file is not owner-writable: #{name}") if
      (stat.mode & 0o200).zero?
  end

  members = File.readlines(File.join(parent, "cgroup.procs"), chomp: true)
                .filter_map do |line|
    Integer(line, 10)
  rescue ArgumentError
    fail!("OpenAI service cgroup has an invalid process member")
  end
  unless members.include?(service_pid)
    fail!("OpenAI service MainPID is outside the delegated service cgroup")
  end

  # This checker intentionally does not move one of its own children into the
  # service cgroup. It runs outside the delegated subtree. cgroups(7) requires
  # write access to cgroup.procs in the nearest common ancestor of source and
  # destination, so such a cross-boundary move is correctly denied. Actual
  # strict-ownership cgroup creation/migration/kill is exercised through live
  # MCP process execution by the service itself.
rescue SystemCallError => error
  fail!("cannot inspect strict ownership cgroup delegation: #{error.class}")
end


fail!("OpenAI service check must run on Linux") unless
  RbConfig::CONFIG.fetch("host_os").include?("linux")

sonbal = Etc.getpwnam("sonbal")
sonbal_group = Etc.getgrnam("sonbal")
root_group = Etc.getgrnam("root")

unless Process.euid == sonbal.uid
  fail!("OpenAI service check must run as the sonbal execution identity")
end
fail!("sonbal execution identity unexpectedly has uid 0") if sonbal.uid.zero?
fail!("sonbal execution primary group changed") unless
  sonbal.gid == sonbal_group.gid
fail!("sonbal execution identity belongs to root group") if
  numeric_groups!("sonbal").include?(root_group.gid)

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
unless tunnel_id.is_a?(String) && !tunnel_id.empty?
  fail!("OpenAI service acceptance requires a non-empty tunnel_id")
end

fail!("missing OpenAI credential state directory") unless
  File.directory?(state_dir)
dir_stat = File.stat(state_dir)
fail!("OpenAI state directory is not root-owned") unless dir_stat.uid.zero?
fail!("OpenAI state directory group changed") unless
  dir_stat.gid == root_group.gid
assert_mode(state_dir, 0o700)

begin
  secret = File.open(credential, File::RDONLY)
  secret.close
  fail!("non-root checker can read the OpenAI credential")
rescue Errno::EACCES
  # Expected: root:root 0700 state blocks pathname traversal.
rescue Errno::ENOENT
  fail!("OpenAI credential is missing or hidden behind an unexpected path")
end

property_names = %w[
  ActiveState
  SubState
  FragmentPath
  UnitFileState
  User
  Group
  ExecStart
  Restart
  Delegate
  MainPID
]
unit_props = properties(systemctl, unit, property_names)

fail!("OpenAI service is not package-owned") unless
  unit_props["FragmentPath"] == "/usr/lib/systemd/system/#{unit}"
fail!("OpenAI service identity changed") unless
  unit_props["User"] == "sonbal" && unit_props["Group"] == "sonbal"
fail!("OpenAI service executable changed") unless
  unit_props["ExecStart"].include?(expected_args)
fail!("OpenAI service restart policy changed") unless
  unit_props["Restart"] == "on-failure"
fail!("OpenAI service lost strict-ownership cgroup delegation") unless
  unit_props["Delegate"] == "yes"
fail!("OpenAI service must remain disabled during PCA acceptance") unless
  unit_props["UnitFileState"] == "disabled"

rows = process_rows(ps)
candidate_rows = rows.select do |row|
  row[2] == "sonbal" && row[6].include?("--connector openai")
end
openai_rows = candidate_rows.select do |row|
  row[3] == "sonbal" && row[5] == "sonbal" &&
    row[6] == expected_args
end

if expected_state == "stopped"
  if %w[active activating deactivating reloading].include?(
    unit_props["ActiveState"]
  )
    fail!("stopped OpenAI service still reports active transition")
  end
  fail!("stopped OpenAI service retained MainPID") unless
    unit_props["MainPID"] == "0"
  fail!("stopped OpenAI service still has a candidate Sonbal process") unless
    candidate_rows.empty?

  puts "[PASS] Linux OpenAI service stopped and settled"
  exit 0
end

fail!("OpenAI service is not active") unless
  unit_props["ActiveState"] == "active"
fail!("OpenAI service is not running") unless
  unit_props["SubState"] == "running"

main_pid_text = unit_props["MainPID"]
fail!("OpenAI service MainPID is invalid") unless
  main_pid_text.match?(/\A[1-9][0-9]*\z/)
main_pid = Integer(main_pid_text, 10)

rows_by_pid = rows.to_h do |row|
  [Integer(row[0], 10), row]
end
foreign_candidates = candidate_rows.reject do |row|
  descendant_of?(row, main_pid, rows_by_pid)
end
fail!("unexpected OpenAI Sonbal process outside service ownership") unless
  foreign_candidates.empty?

service_roots = openai_rows.select do |row|
  Integer(row[0], 10) == main_pid && Integer(row[1], 10) == 1
end
fail!("expected exactly one systemd-owned OpenAI Sonbal process") unless
  service_roots.length == 1

process = service_roots.fetch(0)
fail!("OpenAI service MainPID does not match process topology") unless
  Integer(process[0], 10) == main_pid
fail!("OpenAI Sonbal process is not parented by systemd") unless
  Integer(process[1], 10) == 1
fail!("OpenAI Sonbal process has a controlling terminal") unless
  process[4] == "?"

sleep 0.25
second_props = properties(
  systemctl, unit, %w[ActiveState SubState MainPID]
)
unless second_props["ActiveState"] == "active" &&
       second_props["SubState"] == "running" &&
       second_props["MainPID"] == main_pid_text
  fail!("OpenAI service did not remain stable")
end

second_rows = process_rows(ps)
stable = second_rows.any? do |row|
  row[0].to_i == main_pid && row[1].to_i == 1 &&
    row[2] == "sonbal" && row[3] == "sonbal" &&
    row[4] == "?" && row[5] == "sonbal" &&
    row[6] == expected_args
end
unless stable
  fail!("OpenAI service process identity changed during stability probe")
end

verify_strict_ownership_delegation!(main_pid, sonbal.uid, sonbal.gid)

puts "[PASS] Linux OpenAI service running with isolated credential boundary"
