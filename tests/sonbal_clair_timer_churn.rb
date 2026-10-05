#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_clair_timer_churn.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "rbconfig"
require "timeout"

executable = File.expand_path(ARGV.fetch(0))
batches = Integer(ENV.fetch("SONBAL_TIMER_CHURN_BATCHES", "50"), 10)
batch_size = Integer(ENV.fetch("SONBAL_TIMER_CHURN_BATCH_SIZE", "100"), 10)
trace = ENV.fetch("SONBAL_TIMER_CHURN_TRACE", "0") == "1"
raise "SONBAL_TIMER_CHURN_BATCHES must be at least 8" unless batches >= 8
raise "SONBAL_TIMER_CHURN_BATCH_SIZE must be positive" unless batch_size.positive?

host_os = RbConfig::CONFIG.fetch("host_os")
platform =
  if host_os.include?("linux")
    "linux"
  elsif host_os.include?("freebsd")
    "freebsd"
  else
    raise "unsupported timer-churn platform: #{host_os}"
  end

if platform == "linux"
  raise "Linux /proc is required for timer churn" unless File.directory?("/proc/self/fd")
else
  ["/bin/ps", "/usr/bin/procstat"].each do |path|
    raise "required FreeBSD resource probe is missing: #{path}" unless File.executable?(path)
  end
end

def capture_freebsd(*argv)
  stdout, stderr, status = Open3.capture3(*argv)
  unless status.success?
    raise "FreeBSD resource probe failed (#{argv.join(' ')}): #{stderr.strip}"
  end
  stdout
end

def resource_sample(platform, pid, batch, timers)
  if platform == "linux"
    wanted = {"VmRSS" => "rss_kib", "VmSize" => "vmsize_kib", "Threads" => "threads"}
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
      raise "FreeBSD ps memory probe is malformed for #{pid}: #{fields.inspect}"
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
        fields_item = line.split
        fields_item.length >= 3 && fields_item.fetch(2).match?(/\A[0-9]+\z/)
      end
    }
    raise "FreeBSD procstat reported no threads for #{pid}" if values.fetch("threads").zero?
  end

  values.merge("batch" => batch, "timers" => timers)
end

def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  return sorted.fetch(middle) if sorted.length.odd?
  (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2.0
end

def read_line(io, timeout, label)
  line = Timeout.timeout(timeout) { io.gets }
  raise "timer-churn fixture closed stdout while waiting for #{label}" if line.nil?
  line.strip
end

samples = []
Open3.popen3(executable, batches.to_s, batch_size.to_s) do |stdin, stdout, stderr, wait_thread|
  pid = wait_thread.pid
  ready = read_line(stdout, 5, "ready")
  raise "timer-churn fixture readiness mismatch: #{ready.inspect}" unless ready == "ready"

  samples << resource_sample(platform, pid, 0, 0)
  stdin.puts("continue")
  stdin.flush

  batches.times do |offset|
    expected = offset + 1
    observed = Integer(read_line(stdout, 10, "batch #{expected}"), 10)
    raise "timer-churn batch mismatch: #{observed} != #{expected}" unless observed == expected
    samples << resource_sample(platform, pid, expected, expected * batch_size)
    stdin.puts("continue")
    stdin.flush
  end

  stdin.close
  status = Timeout.timeout(10) { wait_thread.value }
  fixture_stderr = stderr.read
  raise "timer-churn fixture wrote stderr: #{fixture_stderr.inspect}" unless fixture_stderr.empty?
  raise "timer-churn fixture failed: #{status.inspect}" unless status.success?
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

report = {
  "platform" => platform,
  "kind" => "clair_event_loop_timer_churn",
  "timers" => batches * batch_size,
  "batches" => batches,
  "batch_size" => batch_size,
  "baseline_rss_kib" => baseline.fetch("rss_kib"),
  "final_rss_kib" => final.fetch("rss_kib"),
  "peak_rss_kib" => samples.map { |item| item.fetch("rss_kib") }.max,
  "baseline_vmsize_kib" => baseline.fetch("vmsize_kib"),
  "final_vmsize_kib" => final.fetch("vmsize_kib"),
  "peak_vmsize_kib" => samples.map { |item| item.fetch("vmsize_kib") }.max,
  "baseline_threads" => baseline.fetch("threads"),
  "final_threads" => final.fetch("threads"),
  "baseline_fds" => baseline.fetch("fds"),
  "final_fds" => final.fetch("fds"),
  "earlier_tail_median_rss_kib" => earlier_median,
  "later_tail_median_rss_kib" => later_median,
  "rss_stability_allowance_kib" => allowance
}
puts JSON.generate(report)
puts JSON.generate("resource_samples" => samples) if trace

if final.fetch("threads") != baseline.fetch("threads")
  raise "timer churn changed thread count: #{report.inspect}"
end
if final.fetch("fds") != baseline.fetch("fds")
  raise "timer churn changed FD count: #{report.inspect}"
end
if later_median > earlier_median + allowance
  raise "timer churn RSS tail did not plateau: #{report.inspect}"
end
if final.fetch("rss_kib") > later_median + allowance
  raise "timer churn final RSS escaped plateau: #{report.inspect}"
end

puts "[PASS] Clair Event Loop timer churn resource stability"
