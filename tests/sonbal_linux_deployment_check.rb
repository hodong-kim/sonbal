#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_linux_deployment_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "json"
require "open3"
require "tmpdir"

systemd_analyze = ARGV.fetch(0)
openai_service_unit = File.expand_path(ARGV.fetch(1))
tmpfiles_config = File.expand_path(ARGV.fetch(2))
sysusers_config = File.expand_path(ARGV.fetch(3))
default_config = File.expand_path(ARGV.fetch(4))
openai_config = File.expand_path(ARGV.fetch(5))
platform_config = File.expand_path(ARGV.fetch(6))
debian_preinst = File.expand_path(ARGV.fetch(7))
debian_postinst = File.expand_path(ARGV.fetch(8))
debian_prerm = File.expand_path(ARGV.fetch(9))
debian_postrm = File.expand_path(ARGV.fetch(10))
debian_installed_check = File.expand_path(ARGV.fetch(11))
debian_rules = File.expand_path(ARGV.fetch(12))
debian_control = File.expand_path(ARGV.fetch(13))
package_disclaimer = File.expand_path(ARGV.fetch(14))

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  return stdout if status.success?

  warn "[FAIL] #{command.join(' ')}"
  warn stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  exit 1
end

def effective(text)
  text.lines.reject { |line| line.strip.empty? || line.lstrip.start_with?("#") }
      .join
end

[
  debian_preinst, debian_postinst, debian_prerm, debian_postrm
].each { |path| run!("/bin/sh", "-n", path) }

service_text = File.read(openai_service_unit, encoding: "UTF-8")
Dir.mktmpdir("sonbal-systemd-verify-") do |dir|
  verify = File.join(dir, "sonbal-openai.service")
  File.write(
    verify,
    service_text.sub(
      "ExecStart=/usr/bin/sonbal --connector openai",
      "ExecStart=/usr/bin/true --connector openai"
    )
  )
  run!(systemd_analyze, "verify", verify)
end

[
  "ExecStart=/usr/bin/sonbal --connector openai",
  "User=sonbal",
  "Group=sonbal",
  "UMask=0002",
  "OpenFile=/var/lib/sonbal-openai/credential:openai-credential:read-only",
  "StandardInput=null",
  "StandardOutput=null",
  "StandardError=journal",
  "Delegate=yes",
  "KillMode=mixed",
  "KillSignal=SIGTERM",
  "TimeoutStopSec=15s",
  "Restart=on-failure",
  "RestartSec=2s",
  "StartLimitIntervalSec=60s",
  "StartLimitBurst=5",
  "WantedBy=multi-user.target"
].each do |token|
  fail!("OpenAI systemd contract lost #{token.inspect}") unless
    service_text.include?(token)
end
fail!("OpenAI unit must inject exactly one startup file descriptor") unless
  service_text.scan(/^OpenFile=/).length == 1
if service_text.match?(/^Environment=.*(?:API_KEY|credential)/i) ||
   service_text.include?("LoadCredential=") ||
   service_text.include?("Sockets=")
  fail!("OpenAI service gained alternate secret/activation path")
end

sysusers = effective(File.read(sysusers_config, encoding: "UTF-8"))
fail!("sysusers must create exactly the Sonbal execution identity") unless
  sysusers.lines.map(&:strip) == [
    'u sonbal - "Sonbal execution service" /nonexistent /usr/sbin/nologin'
  ]

tmpfiles = effective(File.read(tmpfiles_config, encoding: "UTF-8"))
fail!("tmpfiles must own only root OpenAI credential state") unless
  tmpfiles.lines.map(&:strip) == ["d /var/lib/sonbal-openai 0700 root root -"]

default_text = File.read(default_config, encoding: "UTF-8")
fail!("default config gained secret state") if
  default_text.match?(/api[_-]?key|credential|secret/i)
openai_text = File.read(openai_config, encoding: "UTF-8")
begin
  openai = JSON.parse(openai_text)
rescue JSON::ParserError => error
  fail!("OpenAI config is invalid JSON: #{error.message}")
end
fail!("OpenAI config must fail closed with empty tunnel_id") unless
  openai == { "tunnel_id" => "" }
fail!("OpenAI config gained secret state") if
  openai_text.match?(/credential|api[_-]?key|secret/i)

platform_text = File.read(platform_config, encoding: "UTF-8")
[
  '"/usr/lib/sonbal/connectors/libsonbal_connector_openai.so"',
  '"/etc/sonbal/openai.json"'
].each do |token|
  fail!("Linux platform config lost #{token}") unless platform_text.include?(token)
end

preinst = File.read(debian_preinst, encoding: "UTF-8")
[
  "pre-existing execution identity resolves to root",
  "pre-existing execution identity primary GID is root",
  "pre-existing execution identity primary group is not sonbal",
  "pre-existing execution identity is not non-login"
].each { |token| fail!("preinst lost #{token.inspect}") unless preinst.include?(token) }

disclaimer_text = File.read(package_disclaimer, encoding: "UTF-8")
disclaimer_flat = disclaimer_text.gsub(/\s+/, " ")
[
  "AI systems can make mistakes or behave unexpectedly",
  "isolated or restricted environment",
  "Installation does not start Sonbal",
  "Use Sonbal at your own risk"
].each do |token|
  fail!("package disclaimer lost #{token.inspect}") unless
    disclaimer_flat.include?(token)
end

postinst = File.read(debian_postinst, encoding: "UTF-8")
[
  "unsafe execution service identity",
  "deb-systemd-helper update-state sonbal-openai.service",
  "/usr/bin/systemctl --system daemon-reload",
  "/usr/share/doc/sonbal/package-disclaimer.txt",
  "/bin/cat \"$disclaimer\""
].each { |token| fail!("postinst lost #{token.inspect}") unless postinst.include?(token) }
if postinst.include?("deb-systemd-invoke") ||
   postinst.match?(/systemctl .*\b(?:start|restart|enable)\b/)
  fail!("postinst must remain activation-neutral")
end
fail!("postinst disclaimer must remain noninteractive") if
  postinst.match?(/^\s*read\b/)

prerm = File.read(debian_prerm, encoding: "UTF-8")
[
  "deb-systemd-invoke stop sonbal-openai.service",
  "--property=ActiveState",
  "--property=MainPID",
  "--property=ControlGroup",
  "cgroup.events",
  "refusing package removal while service shutdown is incomplete"
].each { |token| fail!("prerm lost #{token.inspect}") unless prerm.include?(token) }

postrm = File.read(debian_postrm, encoding: "UTF-8")
[
  "deb-systemd-helper purge sonbal-openai.service",
  "/etc/systemd/system/multi-user.target.wants/sonbal-openai.service",
  "/usr/bin/systemctl --system daemon-reload"
].each { |token| fail!("postrm lost #{token.inspect}") unless postrm.include?(token) }

lifecycle_text = [preinst, postinst, prerm, postrm].join("\n")
%w[fastcgi sonbal-tunnel tunnel-client nginx fasyn].each do |term|
  fail!("Debian lifecycle retained retired ingress term #{term}") if
    lifecycle_text.downcase.include?(term)
end

rules = File.read(debian_rules, encoding: "UTF-8")
build_rule = rules[/^override_dh_auto_build:\n(?:\t.*\n)+/]
fail!("Debian build override is missing") if build_rule.nil?
workspace = build_rule.index("rake package-workspace-check")
build = build_rule.index("rake build")
metadata = build_rule.index("rake debian-package-metadata")
unless workspace && build && metadata && workspace < build && build < metadata
  fail!("package workspace/build/metadata ordering changed")
end
systemd_rule = rules[/^override_dh_installsystemd:\n(?:\t.*\n)+/]
fail!("Debian systemd packaging override is missing") if systemd_rule.nil?
unless systemd_rule.include?(
  "dh_installsystemd --no-scripts sonbal-openai.service"
)
  fail!("Debian systemd packaging must be activation-neutral")
end
fail!("Debian package no longer sanitizes product binary") unless
  rules.include?("debian/sonbal/usr/bin/sonbal")
fail!("Debian package no longer sanitizes OpenAI connector") unless
  rules.include?("libsonbal_connector_openai.so")

control = File.read(debian_control, encoding: "UTF-8")
fail!("Debian runtime must require systemd OpenFile support") unless
  control.match?(/^Depends:.*systemd \(>= 253\)/)
fail!("Debian build lost libcurl development dependency") unless
  control.include?("libcurl4-openssl-dev")
fail!("Debian package description is not connector-only") unless
  control.include?("single in-process OpenAI connector service")

installed_text = File.read(debian_installed_check, encoding: "UTF-8")
fail!("installed checker lost connector package identity") unless
  installed_text.include?("sonbal-openai.service") &&
    installed_text.include?("libsonbal_connector_openai.so")

puts "[PASS] Linux connector-only deployment templates"
