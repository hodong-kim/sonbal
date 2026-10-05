#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_clair_watch_churn.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "rbconfig"
require "socket"
require "timeout"

executable = File.expand_path(ARGV.fetch(0))
batches = Integer(ENV.fetch("SONBAL_WATCH_CHURN_BATCHES", "50"), 10)
batch_size = Integer(ENV.fetch("SONBAL_WATCH_CHURN_BATCH_SIZE", "100"), 10)
trace = ENV.fetch("SONBAL_WATCH_CHURN_TRACE", "0") == "1"
raise "SONBAL_WATCH_CHURN_BATCHES must be at least 8" unless batches >= 8
raise "SONBAL_WATCH_CHURN_BATCH_SIZE must be positive" unless batch_size.positive?

host_os = RbConfig::CONFIG.fetch("host_os")
platform =
  if host_os.include?("linux")
    "linux"
  elsif host_os.include?("freebsd")
    "freebsd"
  else
    raise "unsupported watch-churn platform: #{host_os}"
  end

CASES = %w[modify_watch remove_add_watch].freeze


def capture_freebsd(*argv)
  stdout, stderr, status = Open3.capture3(*argv)
  unless status.success?
    raise "FreeBSD resource probe failed (#{argv.join(' ')}): #{stderr.strip}"
  end
  stdout
end


def resource_sample(platform, pid, batch, cycles)
  if platform == "linux"
    wanted = {
      "VmRSS" => "rss_kib",
      "VmSize" => "vmsize_kib",
      "Threads" => "threads"
    }
    values = {}
    File.foreach("/proc/#{pid}/status") do |line|
      key, rest = line.split(":", 2)
      target = wanted[key]
      next if target.nil?

      values[target] = Integer(rest.split.fetch(0), 10)
    end
    missing = wanted.values.reject { |key| values.key?(key) }
    raise "Linux process metrics missing: #{missing.join(', ')}" unless missing.empty?
    values["fds"] = Dir.children("/proc/#{pid}/fd").length
  else
    fields = capture_freebsd(
      "/bin/ps", "-o", "rss=", "-o", "vsz=", "-p", pid.to_s
    ).split
    unless fields.length == 2
      raise "FreeBSD ps memory probe malformed: #{fields.inspect}"
    end
    values = {
      "rss_kib" => Integer(fields.fetch(0), 10),
      "vmsize_kib" => Integer(fields.fetch(1), 10),
      "threads" => capture_freebsd(
        "/usr/bin/procstat", "-t", "-h", pid.to_s
      ).lines.count { |line| !line.strip.empty? },
      "fds" => capture_freebsd(
        "/usr/bin/procstat", "-f", "-h", pid.to_s
      ).lines.count do |line|
        item = line.split
        item.length >= 3 && item.fetch(2).match?(/\A[0-9]+\z/)
      end
    }
  end

  values.merge("batch" => batch, "cycles" => cycles)
end


def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  return sorted.fetch(middle) if sorted.length.odd?

  (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2.0
end


def read_line(io, timeout, label)
  line = Timeout.timeout(timeout) { io.gets }
  raise "watch-churn fixture closed stdout while waiting for #{label}" if line.nil?

  line.strip
end


def reap_failed_child(pid)
  Process.kill("TERM", pid)
rescue Errno::ESRCH
  return
ensure
  begin
    Timeout.timeout(2) { Process.wait(pid) }
  rescue Errno::ECHILD
    nil
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
  end
end


def run_case(executable, platform, batches, batch_size, label, trace)
  stdin_r, stdin_w = IO.pipe
  stdout_r, stdout_w = IO.pipe
  err_r, err_w = IO.pipe
  watch_parent, watch_child = Socket.pair(:UNIX, :STREAM, 0)
  pid = Process.spawn(
    executable, label, batches.to_s, batch_size.to_s,
    in: stdin_r, out: stdout_w, err: err_w, 3 => watch_child,
    close_others: true
  )
  stdin_r.close
  stdout_w.close
  err_w.close
  watch_child.close
  samples = []
  reaped = false

  begin
    ready = read_line(stdout_r, 10, "#{label} readiness")
    unless ready == "ready"
      raise "watch-churn readiness mismatch for #{label}: #{ready.inspect}"
    end

    samples << resource_sample(platform, pid, 0, 0)
    stdin_w.puts("continue")
    stdin_w.flush

    batches.times do |offset|
      expected = offset + 1
      observed = Integer(
        read_line(stdout_r, 10, "#{label} batch #{expected}"), 10
      )
      unless observed == expected
        raise "watch-churn batch mismatch for #{label}: #{observed} != #{expected}"
      end
      samples << resource_sample(
        platform, pid, expected, expected * batch_size
      )
      stdin_w.puts("continue")
      stdin_w.flush
    end

    stdin_w.close
    status = Timeout.timeout(10) { Process.wait2(pid).last }
    reaped = true
    fixture_stderr = err_r.read
    unless fixture_stderr.empty?
      raise "watch-churn fixture wrote stderr for #{label}: #{fixture_stderr.inspect}"
    end
    raise "watch-churn fixture failed for #{label}: #{status.inspect}" unless status.success?
  ensure
    stdin_w.close unless stdin_w.closed?
    stdout_r.close unless stdout_r.closed?
    err_r.close unless err_r.closed?
    watch_parent.close unless watch_parent.closed?
    reap_failed_child(pid) unless reaped
  end

  baseline = samples.first
  final = samples.last
  late = samples[(samples.length / 2)..]
  split = late.length / 2
  earlier = late[0, split]
  later = late[split, late.length]
  earlier_median = median(earlier.map { |item| item.fetch("rss_kib") })
  later_median = median(later.map { |item| item.fetch("rss_kib") })
  allowance = [512, (earlier_median * 0.05).ceil].max
  rss_values = samples.map { |item| item.fetch("rss_kib") }
  rss_deltas = rss_values.each_cons(2).map { |before, after| after - before }
  positive_rss_steps = rss_deltas.count(&:positive?)
  sustained_step_threshold = (rss_deltas.length * 3 + 3) / 4
  total_rss_growth = final.fetch("rss_kib") - baseline.fetch("rss_kib")
  sustained_growth =
    total_rss_growth > 256 && positive_rss_steps >= sustained_step_threshold

  report = {
    "platform" => platform,
    "kind" => "clair_event_loop_watch_churn",
    "case" => label,
    "cycles" => batches * batch_size,
    "batches" => batches,
    "batch_size" => batch_size,
    "baseline_rss_kib" => baseline.fetch("rss_kib"),
    "final_rss_kib" => final.fetch("rss_kib"),
    "peak_rss_kib" => rss_values.max,
    "baseline_vmsize_kib" => baseline.fetch("vmsize_kib"),
    "final_vmsize_kib" => final.fetch("vmsize_kib"),
    "peak_vmsize_kib" => samples.map { |item| item.fetch("vmsize_kib") }.max,
    "baseline_threads" => baseline.fetch("threads"),
    "final_threads" => final.fetch("threads"),
    "baseline_fds" => baseline.fetch("fds"),
    "final_fds" => final.fetch("fds"),
    "earlier_tail_median_rss_kib" => earlier_median,
    "later_tail_median_rss_kib" => later_median,
    "rss_stability_allowance_kib" => allowance,
    "rss_total_growth_kib" => total_rss_growth,
    "positive_rss_steps" => positive_rss_steps,
    "rss_step_count" => rss_deltas.length
  }
  puts JSON.generate(report)
  if trace
    puts JSON.generate("case" => label, "resource_samples" => samples)
  end

  failures = []
  failures << "thread count changed" if final.fetch("threads") != baseline.fetch("threads")
  failures << "FD count changed" if final.fetch("fds") != baseline.fetch("fds")
  failures << "RSS tail did not plateau" if later_median > earlier_median + allowance
  failures << "final RSS escaped plateau" if final.fetch("rss_kib") > later_median + allowance
  failures << "sustained RSS growth" if sustained_growth

  if failures.empty?
    puts "[PASS] Clair Event Loop watch #{label} resource stability"
  end
  [report, failures]
end

failures = []
CASES.each do |label|
  report, case_failures = run_case(
    executable, platform, batches, batch_size, label, trace
  )
  next if case_failures.empty?

  failures << "#{label}: #{case_failures.join(', ')}: #{report.inspect}"
end

unless failures.empty?
  raise "Clair Event Loop watch churn failed: #{failures.join(' | ')}"
end
