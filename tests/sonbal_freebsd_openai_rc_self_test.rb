#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_freebsd_openai_rc_self_test.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

openai_rc = File.expand_path(ARGV.fetch(0))
repo_root = File.expand_path("..", __dir__)
tmp_root = File.join(repo_root, "build", "tmp")
FileUtils.mkdir_p(tmp_root)

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def instrument_rc(source_path, destination)
  source = File.read(source_path, encoding: "UTF-8")
  rc_subr = ". /etc/rc.subr\n"
  load_config = /^load_rc_config \"\$name\"\n/
  run_command = /^run_rc_command \"\$1\"\s*\z/

  fail!("#{source_path} lost rc.subr") unless source.include?(rc_subr)
  fail!("#{source_path} lost load_rc_config") unless source.match?(load_config)
  fail!("#{source_path} lost run_rc_command") unless source.match?(run_command)

  source = source.sub(rc_subr, "")
  source = source.sub(load_config, "")
  source = source.sub(run_command, "")

  replacements = {
    "/bin/kill" => "mock_kill",
    "/bin/pwait" => "mock_pwait",
    "/bin/rm" => "mock_rm",
    "/bin/sleep" => "mock_sleep",
    "/bin/ps" => "mock_ps",
    "/usr/bin/env" => "mock_env",
    "/usr/bin/id" => "mock_id",
    "/usr/bin/install" => "mock_install",
    "/usr/bin/pgrep" => "mock_pgrep",
    "/usr/bin/procstat" => "mock_procstat",
    "/usr/bin/stat" => "mock_stat"
  }
  replacements.each { |native, mock| source = source.gsub(native, mock) }

  retained = replacements.keys.select { |native| source.include?(native) }
  unless retained.empty?
    fail!("instrumentation retained native commands: #{retained.join(', ')}")
  end

  File.write(destination, source)
end

def monotonic_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end


def run_real_daemon_fd_test(root)
  case_dir = File.join(root, "real-daemon-fd3")
  FileUtils.mkdir_p(case_dir)
  credential_path = File.join(case_dir, "credential")
  marker_path = File.join(case_dir, "fd3-observed")
  term_marker_path = File.join(case_dir, "term-observed")
  supervisor_pidfile = File.join(case_dir, "supervisor.pid")
  child_pidfile = File.join(case_dir, "child.pid")
  helper_path = File.join(case_dir, "read-fd3.sh")

  File.write(credential_path, "synthetic-openai-credential\n")
  File.write(helper_path, <<~'SH')
    expected='synthetic-openai-credential'
    marker="$1"
    term_marker="$2"
    trap 'printf "%s\n" term-ok > "$term_marker"; exit 0' TERM
    IFS= read -r value <&3 || exit 11
    [ "$value" = "$expected" ] || exit 12
    printf '%s\n' fd3-ok > "$marker"
    exec 3<&-
    while :; do
      /bin/sleep 1
    done
  SH

  File.open(credential_path, File::RDONLY) do |credential|
    launcher_pid = Process.spawn(
      "/usr/sbin/daemon", "-f",
      "-P", supervisor_pidfile, "-p", child_pidfile,
      "/bin/sh", helper_path, marker_path, term_marker_path,
      3 => credential, close_others: true
    )
    _, status = Process.wait2(launcher_pid)
    fail!("real daemon fd-3 launcher failed") unless status.success?
  end

  deadline = monotonic_now + 5.0
  until File.file?(marker_path) && File.file?(supervisor_pidfile) &&
        File.file?(child_pidfile)
    fail!("real daemon did not preserve fd 3 to its child") if
      monotonic_now >= deadline
    sleep 0.01
  end
  fail!("real daemon fd-3 child observed wrong value") unless
    File.read(marker_path, encoding: "UTF-8") == "fd3-ok\n"

  supervisor_pid = Integer(File.read(supervisor_pidfile).strip, 10)
  child_pid = Integer(File.read(child_pidfile).strip, 10)
  Process.kill("TERM", supervisor_pid)

  deadline = monotonic_now + 5.0
  until File.file?(term_marker_path)
    fail!("real daemon did not forward SIGTERM to its child") if
      monotonic_now >= deadline
    sleep 0.01
  end
  fail!("real daemon child observed wrong SIGTERM state") unless
    File.read(term_marker_path, encoding: "UTF-8") == "term-ok\n"

  while File.exist?(supervisor_pidfile) || File.exist?(child_pidfile)
    fail!("real daemon fd-3 probe did not settle") if monotonic_now >= deadline
    sleep 0.01
  end

  remaining_pids = [child_pid, supervisor_pid]
  deadline = monotonic_now + 5.0
  until remaining_pids.empty?
    remaining_pids.select! do |pid|
      begin
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end
    end
    break if remaining_pids.empty?
    fail!("real daemon fd-3 probe left live processes") if
      monotonic_now >= deadline
    sleep 0.01
  end
rescue ArgumentError
  fail!("real daemon fd-3 probe produced an invalid pidfile")
end

def run_case(name, rc_path, root, body)
  case_dir = File.join(root, name)
  FileUtils.mkdir_p(case_dir)
  event_log = File.join(case_dir, "events.log")
  stderr_log = File.join(case_dir, "stderr.log")
  script = File.join(case_dir, "case.sh")

  File.write(script, <<~SH)
    EVENT_LOG=#{Shellwords.escape(event_log)}
    STDERR_LOG=#{Shellwords.escape(stderr_log)}
    CASE_DIR=#{Shellwords.escape(case_dir)}
    : > "$EVENT_LOG"
    : > "$STDERR_LOG"

    . #{Shellwords.escape(rc_path)}

    mock_kill()
    {
      printf 'kill %s\n' "$*" >> "$EVENT_LOG"
      return 1
    }

    mock_pwait()
    {
      printf 'pwait %s\n' "$*" >> "$EVENT_LOG"
      return 0
    }

    mock_rm()
    {
      printf 'rm %s\n' "$*" >> "$EVENT_LOG"
      return 0
    }

    mock_sleep()
    {
      return 0
    }

    mock_ps()
    {
      return 1
    }

    mock_env()
    {
      printf 'env %s\n' "$*" >> "$EVENT_LOG"
      return 1
    }

    mock_id()
    {
      printf '%s\n' 2001
      return 0
    }

    mock_install()
    {
      return 1
    }

    mock_pgrep()
    {
      return 1
    }

    mock_procstat()
    {
      return 1
    }

    mock_stat()
    {
      return 1
    }

    #{body}
  SH

  stdout, stderr, status = Open3.capture3("/bin/sh", script)
  return [File.read(event_log), File.read(stderr_log)] if status.success?

  fail!(
    "#{name} failed with #{status.exitstatus}: " \
    "stdout=#{stdout.strip.inspect} stderr=#{stderr.strip.inspect}"
  )
end

unless RUBY_PLATFORM.include?("freebsd")
  fail!("FreeBSD OpenAI rc.d self-test must run on FreeBSD")
end

Dir.mktmpdir("sonbal-freebsd-openai-", tmp_root) do |root|
  run_real_daemon_fd_test(root)

  rc_copy = File.join(root, "sonbal_openai")
  instrument_rc(openai_rc, rc_copy)

  run_case("startup-fd3-and-umask", rc_copy, root, <<~'SH')
    state_dir="$CASE_DIR/state"
    credential="$state_dir/credential"
    configuration="$CASE_DIR/openai.json"
    sonbal_command="/usr/bin/true"
    supervisor_pidfile="$CASE_DIR/supervisor.pid"
    child_pidfile="$CASE_DIR/child.pid"
    /bin/mkdir -p "$state_dir"
    printf '%s\n' 'synthetic-openai-credential' > "$credential"
    printf '%s\n' '{"tunnel_id":"fixture"}' > "$configuration"
    umask 022

    sonbal_openai_instances() { return 0; }
    sonbal_openai_supervisor_pid() { return 0; }
    sonbal_openai_wait_start() { return 0; }
    sonbal_openai_status() { return 0; }

    mock_stat()
    {
      case "$3" in
        "$state_dir") printf '%s\n' 'root:wheel:700' ;;
        "$credential") printf '%s\n' 'root:wheel:600' ;;
        *) return 91 ;;
      esac
      return 0
    }

    mock_env()
    {
      printf 'env %s\n' "$*" >> "$EVENT_LOG"
      [ "$(umask)" = "0002" ] || return 92
      IFS= read -r credential_value <&3 || return 93
      [ "$credential_value" = 'synthetic-openai-credential' ] || return 94
      : > "$CASE_DIR/fd3-observed"
      return 0
    }

    status=0
    sonbal_openai_start >/dev/null 2>"$STDERR_LOG" || status=$?
    [ "$status" -eq 0 ] || exit 1
    [ -f "$CASE_DIR/fd3-observed" ] || exit 2
    expected="-i PATH=/usr/local/bin:/usr/bin:/bin /usr/sbin/daemon "
    expected="${expected}-f -P $supervisor_pidfile -p $child_pidfile "
    expected="${expected}-u sonbal /usr/bin/true --connector openai"
    /usr/bin/grep -F "env $expected" "$EVENT_LOG" >/dev/null || exit 3
  SH

  run_case("wrong-credential-mode-fails-before-launch", rc_copy, root, <<~'SH')
    state_dir="$CASE_DIR/state"
    credential="$state_dir/credential"
    configuration="$CASE_DIR/openai.json"
    sonbal_command="/usr/bin/true"
    /bin/mkdir -p "$state_dir"
    printf '%s\n' synthetic > "$credential"
    printf '%s\n' '{"tunnel_id":"fixture"}' > "$configuration"

    sonbal_openai_instances() { return 0; }
    sonbal_openai_supervisor_pid() { return 0; }

    mock_stat()
    {
      case "$3" in
        "$state_dir") printf '%s\n' 'root:wheel:700' ;;
        "$credential") printf '%s\n' 'root:wheel:640' ;;
        *) return 91 ;;
      esac
      return 0
    }

    mock_env()
    {
      : > "$CASE_DIR/launched"
      return 0
    }

    status=0
    sonbal_openai_start >/dev/null 2>"$STDERR_LOG" || status=$?
    [ "$status" -ne 0 ] || exit 4
    [ ! -f "$CASE_DIR/launched" ] || exit 5
  SH

  run_case("pathname-loss-needs-verified-parent", rc_copy, root, <<~'SH')
    sonbal_pattern="/usr/local/bin/sonbal --connector openai"
    child_pidfile="$CASE_DIR/child.pid"
    printf '%s\n' 501 > "$child_pidfile"

    mock_pgrep()
    {
      printf '%s\n' 501
      return 0
    }

    mock_procstat()
    {
      printf '%s\n' \
        'procstat: sysctl: kern.proc.pathname: 501: No such file or directory'
      return 1
    }

    mock_kill()
    {
      [ "$1" = '-0' ] && return 0
      return 1
    }

    mock_ps()
    {
      printf '%s\n' 401
      return 0
    }

    status=0
    sonbal_openai_child_pid >/dev/null 2>"$STDERR_LOG" || status=$?
    [ "$status" -eq 2 ] || exit 6

    status=0
    child=$(sonbal_openai_child_pid 401) || status=$?
    [ "$status" -eq 0 ] || exit 7
    [ "$child" = 501 ] || exit 8
  SH

  events, = run_case("normal-stop-signals-supervisor", rc_copy, root, <<~'SH')
    supervisor_alive=1
    child_alive=1

    sonbal_openai_supervisor_pid() { printf '%s\n' 401; }
    sonbal_openai_instances()
    {
      [ "$child_alive" -eq 1 ] && printf '%s\n' 501
      return 0
    }

    mock_kill()
    {
      printf 'kill %s\n' "$*" >> "$EVENT_LOG"
      if [ "$1" = '-TERM' ] && [ "$2" = 401 ]; then
        supervisor_alive=0
        child_alive=0
        return 0
      fi
      if [ "$1" = '-0' ] && [ "$2" = 401 ]; then
        [ "$supervisor_alive" -eq 1 ]
        return $?
      fi
      return 1
    }

    status=0
    sonbal_openai_stop >/dev/null 2>"$STDERR_LOG" || status=$?
    [ "$status" -eq 0 ] || exit 9
  SH
  unless events.include?("kill -TERM 401")
    fail!("normal stop did not signal verified daemon supervisor")
  end
  if events.include?("kill -KILL")
    fail!("normal stop unexpectedly force-killed the service")
  end

  case_name = "ambiguous-supervisor-retains-pidfiles"
  events, = run_case(case_name, rc_copy, root, <<~'SH')
    sonbal_openai_supervisor_pid() { return 2; }
    sonbal_openai_instances() { printf '%s\n' 501; }
    sonbal_openai_settle_orphans()
    {
      printf 'settle %s\n' "$1" >> "$EVENT_LOG"
      return 0
    }

    status=0
    sonbal_openai_stop >/dev/null 2>"$STDERR_LOG" || status=$?
    [ "$status" -eq 1 ] || exit 10
  SH
  unless events.include?("settle 501")
    fail!("ambiguous supervisor lost exact-child recovery")
  end
  if events.lines.any? { |line| line.start_with?("rm ") }
    fail!("ambiguous supervisor removed retry ownership pidfiles")
  end
end

puts "[PASS] FreeBSD OpenAI rc.d credential and lifecycle self-test"
