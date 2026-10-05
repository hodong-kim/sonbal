#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_freebsd_deployment_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "rbconfig"

openai_rc = File.expand_path(ARGV.fetch(0))
default_config = File.expand_path(ARGV.fetch(1))
openai_config = File.expand_path(ARGV.fetch(2))
platform_config = File.expand_path(ARGV.fetch(3))
pre_install = File.expand_path(ARGV.fetch(4))
pre_deinstall_path = File.expand_path(
  File.join(__dir__, "..", "freebsd", "scripts", "pre-deinstall")
)

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  fail!("#{command.join(' ')}: #{stderr.strip}") unless status.success?
  stdout
end

fail!("FreeBSD deployment check must run on FreeBSD") unless
  RUBY_PLATFORM.include?("freebsd")
fail!("FreeBSD package lifecycle must not use pre-deinstall service control") if
  File.file?(pre_deinstall_path)

[openai_rc, pre_install].each { |script| run!("/bin/sh", "-n", script) }

openai_self_test = File.join(
  __dir__, "sonbal_freebsd_openai_rc_self_test.rb"
)
print run!(RbConfig.ruby, openai_self_test, openai_rc)

openai_text = File.read(openai_rc, encoding: "UTF-8")
[
  'name="sonbal_openai"',
  ': ${sonbal_openai_enable:=NO}',
  'state_dir="/var/db/sonbal-openai"',
  'configuration="/usr/local/etc/sonbal/openai.json"',
  'credential="${state_dir}/credential"',
  'sonbal_pattern="/usr/local/bin/sonbal --connector openai"',
  'if ! exec 3< "$credential"; then',
  'exec 3<&-',
  '"$daemon_command" -f -P "$supervisor_pidfile" -p "$child_pidfile"',
  '-u sonbal "$sonbal_command" --connector openai',
  '/usr/bin/install -d -o root -g wheel -m 0700 "$state_dir"',
  '"root:wheel:700"',
  '"root:wheel:600"',
  '/bin/pwait -t 15 "$supervisor_pid"',
  'OpenAI supervisor pidfile identity is ambiguous',
  'retaining pidfiles because supervisor identity',
  'sonbal_openai_rollback_start',
  'OpenAI connector failed final service validation'
].each do |token|
  fail!("OpenAI rc.d lost #{token.inspect}") unless openai_text.include?(token)
end
fail!("OpenAI rc.d gained automatic restart") if
  openai_text.include?('"$daemon_command" -r') ||
    openai_text.include?('"$daemon_command" -R')
fail!("OpenAI rc.d must not carry external ingress integration") if
  openai_text.match?(/fastcgi|tunnel-client|nginx|fasyn/i)

default_text = File.read(default_config, encoding: "UTF-8")
fail!("default config gained secret state") if
  default_text.match?(/api[_-]?key|credential|secret/i)

openai_config_text = File.read(openai_config, encoding: "UTF-8")
begin
  parsed_openai = JSON.parse(openai_config_text)
rescue JSON::ParserError => error
  fail!("OpenAI config is invalid JSON: #{error.message}")
end
fail!("OpenAI config must fail closed with empty tunnel_id") unless
  parsed_openai == { "tunnel_id" => "" }
fail!("OpenAI config gained secret state") if
  openai_config_text.match?(/credential|api[_-]?key|secret/i)

platform_text = File.read(platform_config, encoding: "UTF-8")
[
  '"/usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so"',
  '"/usr/local/etc/sonbal/openai.json"'
].each do |token|
  fail!("FreeBSD platform config lost #{token}") unless
    platform_text.include?(token)
end

pre_install_text = File.read(pre_install, encoding: "UTF-8")
[
  '/usr/sbin/pw -R "$PKG_ROOTDIR" "$@"',
  "groupadd sonbal",
  "useradd sonbal -g sonbal",
  "execution identity unexpectedly resolves to root",
  "execution identity primary GID unexpectedly resolves to root",
  "execution identity is not non-login",
  "execution identity primary group is not sonbal"
].each do |token|
  fail!("FreeBSD pre-install lost #{token.inspect}") unless
    pre_install_text.include?(token)
end
fail!("pre-install must not manage live services") if
  pre_install_text.include?("/usr/sbin/service")
fail!("pre-install retained external ingress identity") if
  pre_install_text.match?(/sonbal-tunnel|tunnel-client|fastcgi|nginx|fasyn/i)

puts "[PASS] FreeBSD connector-only deployment templates"
