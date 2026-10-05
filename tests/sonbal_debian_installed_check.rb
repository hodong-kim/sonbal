#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_debian_installed_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "etc"
require "fileutils"
require "open3"
require "tmpdir"

artifact = File.expand_path(ARGV.fetch(0))
dpkg = ENV.fetch("DPKG", "/usr/bin/dpkg")
dpkg_deb = ENV.fetch("DPKG_DEB", "/usr/bin/dpkg-deb")
dpkg_query = ENV.fetch("DPKG_QUERY", "/usr/bin/dpkg-query")
systemctl = ENV.fetch("SYSTEMCTL", "/usr/bin/systemctl")
ss = ENV.fetch("SS", "/usr/bin/ss")

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  fail!("#{command.join(' ')}: #{stderr.strip}") unless status.success?
  stdout
end

def reject_path(path)
  fail!("retired package path remains: #{path}") if
    File.exist?(path) || File.symlink?(path)
end

def assert_mode(path, expected)
  actual = File.stat(path).mode & 0o7777
  fail!("unexpected mode for #{path}: %04o" % actual) unless actual == expected
end

fail!("installed check must not run as root") if Process.euid.zero?
fail!("Debian package artifact not found: #{artifact}") unless File.file?(artifact)

expected_version = capture!(dpkg_deb, "-f", artifact, "Version").strip
installed = capture!(
  dpkg_query, "-W", "-f=${db:Status-Abbrev} ${Version}", "sonbal"
).strip
fail!("Sonbal package is not installed at #{expected_version}") unless
  installed == "ii  #{expected_version}"

verify_out, verify_err, verify_status = Open3.capture3(dpkg, "-V", "sonbal")
fail!("dpkg verification failed: #{verify_err.strip}") unless verify_status.success?

allowed_modified_conffiles = %w[
  /etc/sonbal/openai.json
  /etc/sonbal/sonbal.yaml
]
verify_out.lines(chomp: true).each do |line|
  match = line.match(/\A\?\?5\?\?\?\?\?\? c (\/.*)\z/)
  fail!("installed package file differs from dpkg metadata: #{line}") if
    match.nil? || !allowed_modified_conffiles.include?(match[1])
end

Dir.mktmpdir("sonbal-installed-check-") do |dir|
  data = File.join(dir, "data")
  FileUtils.mkdir_p(data)
  capture!(dpkg_deb, "-x", artifact, data)
  packaged = File.read(File.join(data, "usr/share/doc/sonbal/sonbal-revisions"))
  installed_revisions = File.read("/usr/share/doc/sonbal/sonbal-revisions")
  fail!("installed revision metadata differs from package artifact") unless
    installed_revisions == packaged
end

%w[
  /usr/bin/sonbal
  /etc/sonbal/sonbal.yaml
  /etc/sonbal/openai.json
  /usr/lib/systemd/system/sonbal-openai.service
  /usr/lib/sonbal/connectors/libsonbal_connector_openai.so
  /usr/lib/sysusers.d/sonbal.conf
  /usr/lib/tmpfiles.d/sonbal.conf
].each do |path|
  fail!("missing installed file: #{path}") unless File.file?(path)
end

%w[
  /usr/lib/systemd/system/sonbal-fastcgi.socket
  /usr/lib/systemd/system/sonbal-fastcgi.service
  /usr/lib/systemd/system/sonbal-tunnel.service
  /etc/nginx/sites-available/sonbal.conf
  /etc/nginx/sites-enabled/sonbal.conf
  /etc/systemd/system/sockets.target.wants/sonbal-fastcgi.socket
  /etc/systemd/system/multi-user.target.wants/sonbal-tunnel.service
].each { |path| reject_path(path) }

execution = Etc.getpwnam("sonbal")
execution_group = Etc.getgrnam("sonbal")
fail!("execution identity unexpectedly resolves to root") if execution.uid.zero?
fail!("execution identity primary GID is root") if execution.gid.zero?
fail!("execution identity primary group is not sonbal") unless
  execution.gid == execution_group.gid
fail!("sonbal is not a non-login identity") unless execution.shell.end_with?("nologin")

state_dir = "/var/lib/sonbal-openai"
state = File.stat(state_dir)
fail!("unexpected OpenAI state owner") unless state.uid.zero?
fail!("unexpected OpenAI state group") unless state.gid.zero?
assert_mode(state_dir, 0o700)

credential = File.join(state_dir, "credential")
begin
  File.open(credential, File::RDONLY) { |_file| }
  fail!("sonbal execution identity can read OpenAI credential")
rescue Errno::EACCES
  nil
rescue Errno::ENOENT
  nil
end

props = capture!(
  systemctl, "show", "sonbal-openai.service",
  "-p", "FragmentPath", "-p", "UnitFileState", "-p", "User", "-p", "Group",
  "-p", "ExecStart", "-p", "Restart"
).lines(chomp: true).to_h { |line| line.split("=", 2) }
fail!("OpenAI service is not package-owned") unless
  props["FragmentPath"] == "/usr/lib/systemd/system/sonbal-openai.service"
fail!("OpenAI service must remain disabled until operator enablement") unless
  props["UnitFileState"] == "disabled"
fail!("OpenAI service identity changed") unless
  props["User"] == "sonbal" && props["Group"] == "sonbal"
fail!("OpenAI service executable changed") unless
  props["ExecStart"].include?("/usr/bin/sonbal --connector openai")
fail!("OpenAI service restart policy changed") unless props["Restart"] == "on-failure"

%w[
  sonbal-fastcgi.socket
  sonbal-fastcgi.service
  sonbal-tunnel.service
].each do |unit|
  load = capture!(systemctl, "show", unit, "-p", "LoadState", "--value").strip
  fail!("retired systemd unit remains loaded: #{unit}") unless load == "not-found"
end

unix_sockets = capture!(ss, "-lx")
[
  "/run/sonbal-fastcgi.sock",
  "/run/sonbal-mcp/http.sock"
].each do |path|
  fail!("retired ingress socket remains: #{path}") if unix_sockets.include?(path)
end

puts "[PASS] installed Debian connector-only package state"
