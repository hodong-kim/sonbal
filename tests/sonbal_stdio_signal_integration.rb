#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_stdio_signal_integration.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "timeout"

product = File.expand_path(ARGV.fetch(0))
restore_fixture = ARGV[1] && File.expand_path(ARGV[1])
process_fixture = File.expand_path(ARGV.fetch(2))

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

def wait_pid_marker(path, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    if File.file?(path)
      text = File.read(path).strip
      begin
        return Integer(text, 10) unless text.empty?
      rescue ArgumentError
        nil
      end
    end
    raise "process marker did not appear" if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def wait_process_absent(pid, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  while process_alive?(pid)
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
  true
end

def process_cgroup_directory(pid)
  path = "/proc/#{pid}/cgroup"
  return nil unless File.file?(path)

  line = File.readlines(path).find { |item| item.start_with?("0::") }
  return nil if line.nil?

  relative = line.split("::", 2).last.strip
  File.join("/sys/fs/cgroup", relative.sub(%r{\A/}, ""))
rescue SystemCallError
  nil
end

def wait_cgroup_absent(path, timeout: 7)
  return true if path.nil?

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  while Dir.exist?(path)
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
  true
end

def cleanup_failed_owned_processes(pids, cgroup_dir)
  pids.compact.each do |pid|
    next unless process_alive?(pid)

    killed = false
    if cgroup_dir
      kill_path = File.join(cgroup_dir, "cgroup.kill")
      if File.file?(kill_path)
        begin
          File.write(kill_path, "1")
          killed = true
        rescue SystemCallError
          killed = false
        end
      end
    end
    unless killed
      begin Process.kill("KILL", pid); rescue Errno::ESRCH; end
    end
    wait_process_absent(pid, timeout: 2)
  end

  return if cgroup_dir.nil? || !Dir.exist?(cgroup_dir)

  events = File.join(cgroup_dir, "cgroup.events")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  while File.file?(events)
    populated = File.readlines(events).find do |line|
      line.start_with?("populated ")
    end
    break if populated&.split&.last == "0"
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
  Dir.rmdir(cgroup_dir) if Dir.exist?(cgroup_dir)
rescue SystemCallError
  nil
end

def workspace_rotate_request(root, label, operation_id: nil)
  arguments = {"root" => root}
  arguments["operation_id"] = operation_id unless operation_id.nil?
  {
    "jsonrpc" => "2.0",
    "id" => "workspace-#{label}",
    "method" => "tools/call",
    "params" => {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {
          "name" => "sonbal-stdio-signal-test",
          "version" => "1"
        }
      },
      "name" => "rotate_workspace_token",
      "arguments" => arguments
    }
  }
end


def rotate_workspace_token(input, output, root, label)
  input.puts(JSON.generate(workspace_rotate_request(root, "#{label}-prepare")))
  input.flush
  line = output.gets
  raise "#{label} workspace token rotation prepare produced no response" if line.nil?

  response = JSON.parse(line)
  result = response.fetch("result")
  structured = result.fetch("structuredContent")
  raise "#{label} workspace token rotation prepare failed" unless
    structured.fetch("status") == "prepared" && result.fetch("isError") == false

  input.puts(
    JSON.generate(
      workspace_rotate_request(
        root,
        "#{label}-commit",
        operation_id: structured.fetch("operation_id")
      )
    )
  )
  input.flush
  line = output.gets
  raise "#{label} workspace token rotation commit produced no response" if line.nil?

  response = JSON.parse(line)
  result = response.fetch("result")
  structured = result.fetch("structuredContent")
  raise "#{label} workspace token rotation failed" unless
    structured.fetch("status") == "rotated" && result.fetch("isError") == false

  structured.fetch("workspace_token")
end


def shutdown_request(marker, label, signal_name, workspace_token, cwd)
  command =
    "printf '%d\\n' $$ > #{Shellwords.escape(marker)}; " \
    "trap '' TERM INT; exec /bin/sleep 60"
  {
    "jsonrpc" => "2.0",
    "id" => "#{signal_name.downcase}-#{label}",
    "method" => "tools/call",
    "params" => {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {
          "name" => "sonbal-stdio-signal-test",
          "version" => "1"
        }
      },
      "name" => "run_process",
      "arguments" => {
        "workspace_token" => workspace_token,
        "argv" => ["/bin/sh", "-c", command],
        "resolution" => "exact_path",
        "cwd" => cwd,
        "timeout_ms" => 100_000
      }
    }
  }
end

def exercise_signal(executable, arguments, label, signal_name)
  Dir.mktmpdir("sonbal-stdio-#{signal_name.downcase}-") do |dir|
    marker = File.join(dir, "owned.pid")
    input = output = error = waiter = nil
    child_pid = nil
    begin
      input, output, error, waiter = Open3.popen3(executable, *arguments)
      workspace_token = rotate_workspace_token(input, output, dir, "#{signal_name.downcase}-#{label}")
      input.puts(
        JSON.generate(
          shutdown_request(marker, label, signal_name, workspace_token, dir)
        )
      )
      input.flush
      child_pid = wait_pid_marker(marker)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill(signal_name, waiter.pid)
      status = Timeout.timeout(10) { waiter.value }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      raise "#{label} #{signal_name} did not exit successfully: #{status.inspect}" unless
        status.success? && !status.signaled?
      raise "#{label} #{signal_name} cleanup exceeded bounded shutdown window" if
        elapsed >= 7.0
      raise "#{label} #{signal_name} left owned process alive" unless
        wait_process_absent(child_pid)

      stderr_text = error.read
      raise "#{label} #{signal_name} wrote stderr: #{stderr_text.inspect}" unless
        stderr_text.empty?
    ensure
      input&.close rescue nil
      output&.close rescue nil
      error&.close rescue nil
      if waiter&.alive?
        begin Process.kill("KILL", waiter.pid); rescue Errno::ESRCH; end
        begin waiter.value; rescue StandardError; end
      end
      if child_pid && process_alive?(child_pid)
        begin Process.kill("KILL", child_pid); rescue Errno::ESRCH; end
      end
    end
  end
end

def owner_death_request(root_marker, descendant_marker, process_fixture, workspace_token, cwd)
  command =
    "printf '%d\\n' $$ > \"$2\"; " \
    "exec \"$1\" hostile-double-fork > \"$3\" 2>/dev/null"
  {
    "jsonrpc" => "2.0",
    "id" => "kill-owner-death",
    "method" => "tools/call",
    "params" => {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {
          "name" => "sonbal-stdio-owner-death-test",
          "version" => "1"
        }
      },
      "name" => "run_process",
      "arguments" => {
        "workspace_token" => workspace_token,
        "argv" => [
          "/bin/sh", "-c", command, "sonbal-owner-death", process_fixture,
          root_marker, descendant_marker
        ],
        "resolution" => "exact_path",
        "cwd" => cwd,
        "timeout_ms" => 100_000
      }
    }
  }
end

def exercise_owner_death(executable, process_fixture)
  Dir.mktmpdir("sonbal-stdio-owner-death-") do |dir|
    root_marker = File.join(dir, "root.pid")
    descendant_marker = File.join(dir, "descendant.pid")
    input = output = error = waiter = nil
    root_pid = nil
    descendant_pid = nil
    cgroup_dir = nil
    begin
      input, output, error, waiter = Open3.popen3(executable)
      workspace_token = rotate_workspace_token(input, output, dir, "owner-death")
      input.puts(
        JSON.generate(
          owner_death_request(
            root_marker,
            descendant_marker,
            process_fixture,
            workspace_token,
            dir
          )
        )
      )
      input.flush
      root_pid = wait_pid_marker(root_marker)
      descendant_pid = wait_pid_marker(descendant_marker)
      cgroup_dir = process_cgroup_directory(descendant_pid)

      Process.kill("KILL", waiter.pid)
      status = Timeout.timeout(3) { waiter.value }
      unless status.signaled? && status.termsig == Signal.list.fetch("KILL")
        raise "stdio owner host did not die by SIGKILL: #{status.inspect}"
      end
      unless wait_process_absent(root_pid, timeout: 7)
        raise "stdio owner death left strict-owned root process alive"
      end
      unless wait_process_absent(descendant_pid, timeout: 7)
        raise "stdio owner death left topology-escaping descendant alive"
      end
      unless wait_cgroup_absent(cgroup_dir, timeout: 7)
        raise "stdio owner death retained strict-ownership cgroup"
      end

      stderr_text = error.read
      unless stderr_text.empty?
        raise "stdio owner-death probe wrote stderr: #{stderr_text.inspect}"
      end
    ensure
      input&.close rescue nil
      output&.close rescue nil
      error&.close rescue nil
      if waiter&.alive?
        begin Process.kill("KILL", waiter.pid); rescue Errno::ESRCH; end
        begin waiter.value; rescue StandardError; end
      end
      cleanup_failed_owned_processes([root_pid, descendant_pid], cgroup_dir)
    end
  end
end

["TERM", "INT"].each do |signal_name|
  exercise_signal(product, [], "product", signal_name)
  puts "[PASS] stdio SIG#{signal_name} settles strict-owned process"
end

exercise_owner_death(product, process_fixture)
puts "[PASS] stdio SIGKILL owner death settles topology-escaping domain"

if restore_fixture
  {
    "TERM" => "--stdio-sigterm-restore",
    "INT" => "--stdio-sigint-restore"
  }.each do |signal_name, mode|
    exercise_signal(restore_fixture, [mode], "restore fixture", signal_name)
    puts "[PASS] stdio SIG#{signal_name} restores process signal action"
  end
end
