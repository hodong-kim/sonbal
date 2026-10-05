#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_debian_package_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "fileutils"
require "json"
require "open3"
require "tmpdir"

artifact = File.expand_path(ARGV.fetch(0))
expected_version = ARGV.fetch(1)
expected_sonbal = ARGV.fetch(2)
expected_clair = ARGV.fetch(3)
dpkg_deb = ENV.fetch("DPKG_DEB", "/usr/bin/dpkg-deb")
repo_root = File.expand_path("..", __dir__)
expected_disclaimer = File.read(
  File.join(repo_root, "deployment", "package-disclaimer.txt"),
  encoding: "UTF-8"
)

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  fail!("#{command.join(' ')}: #{stderr.strip}") unless status.success?
  stdout
end

def require_file!(root, relative)
  path = File.join(root, relative)
  fail!("missing package path: #{relative}") unless File.file?(path)
  path
end

def reject_path!(root, relative)
  path = File.join(root, relative)
  fail!("retired package path remains: #{relative}") if
    File.exist?(path) || File.symlink?(path)
end

fail!("Debian package artifact not found") unless File.file?(artifact)
version = capture!(dpkg_deb, "-f", artifact, "Version").strip
fail!("unexpected package version #{version.inspect}") unless
  version == expected_version

depends = capture!(dpkg_deb, "-f", artifact, "Depends").strip
fail!("systemd OpenFile dependency missing") unless
  depends.match?(/(?:^|, )systemd \(>= 253\)(?:,|$)/)

Dir.mktmpdir("sonbal-debian-check-") do |dir|
  data = File.join(dir, "data")
  control = File.join(dir, "control")
  FileUtils.mkdir_p(data)
  FileUtils.mkdir_p(control)
  capture!(dpkg_deb, "-x", artifact, data)
  capture!(dpkg_deb, "-e", artifact, control)

  %w[
    usr/bin/sonbal
    usr/lib/sonbal/connectors/libsonbal_connector_openai.so
    etc/sonbal/sonbal.yaml
    etc/sonbal/openai.json
    usr/lib/systemd/system/sonbal-openai.service
    usr/lib/sysusers.d/sonbal.conf
    usr/lib/tmpfiles.d/sonbal.conf
    usr/share/doc/sonbal/sonbal-revisions
    usr/share/doc/sonbal/package-disclaimer.txt
  ].each { |path| require_file!(data, path) }

  disclaimer = File.read(
    require_file!(data, "usr/share/doc/sonbal/package-disclaimer.txt"),
    encoding: "UTF-8"
  )
  fail!("packaged disclaimer differs from canonical source") unless
    disclaimer == expected_disclaimer

  revisions = File.read(
    require_file!(data, "usr/share/doc/sonbal/sonbal-revisions")
  ).lines(chomp: true).to_h { |line| line.split("=", 2) }
  expected_metadata = {
    "package_version" => expected_version,
    "sonbal_commit" => expected_sonbal,
    "sonbal_build_profile" => "release",
    "clair_commit" => expected_clair,
    "clair_build_profile" => "release"
  }
  expected_metadata.each do |key, value|
    fail!("revision metadata mismatch for #{key}") unless revisions[key] == value
  end
  fail!("unexpected dependency provenance remains") unless
    revisions.keys.sort == (expected_metadata.keys + ["sonbal_release"]).sort

  conffiles = File.readlines(File.join(control, "conffiles"), chomp: true).sort
  expected_conffiles = [
    "/etc/sonbal/openai.json",
    "/etc/sonbal/sonbal.yaml"
  ].sort
  fail!("unexpected conffile set #{conffiles.inspect}") unless
    conffiles == expected_conffiles

  unit = File.read(
    require_file!(data, "usr/lib/systemd/system/sonbal-openai.service")
  )
  [
    "User=sonbal",
    "Group=sonbal",
    "ExecStart=/usr/bin/sonbal --connector openai",
    "UMask=0002",
    "OpenFile=/var/lib/sonbal-openai/credential:openai-credential:read-only",
    "TimeoutStopSec=15s",
    "KillSignal=SIGTERM",
    "KillMode=mixed",
    "Restart=on-failure",
    "WantedBy=multi-user.target"
  ].each do |token|
    fail!("OpenAI service lost #{token.inspect}") unless unit.include?(token)
  end
  fail!("OpenAI service gained alternate secret injection") if
    unit.include?("LoadCredential=") ||
      unit.match?(/^Environment=.*(?:API_KEY|credential)/i)

  openai_text = File.read(require_file!(data, "etc/sonbal/openai.json"))
  begin
    parsed = JSON.parse(openai_text)
  rescue JSON::ParserError => error
    fail!("packaged OpenAI config is invalid: #{error.message}")
  end
  fail!("packaged OpenAI config is not fail-closed") unless
    parsed == { "tunnel_id" => "" }

  sysusers = File.read(require_file!(data, "usr/lib/sysusers.d/sonbal.conf"))
  effective_users = sysusers.lines.reject do |line|
    line.strip.empty? || line.lstrip.start_with?("#")
  end.map(&:strip)
  fail!("unexpected packaged service identities") unless
    effective_users == [
      'u sonbal - "Sonbal execution service" /nonexistent /usr/sbin/nologin'
    ]

  tmpfiles = File.read(require_file!(data, "usr/lib/tmpfiles.d/sonbal.conf"))
  effective_tmpfiles = tmpfiles.lines.reject do |line|
    line.strip.empty? || line.lstrip.start_with?("#")
  end.map(&:strip)
  fail!("unexpected packaged runtime state") unless
    effective_tmpfiles == ["d /var/lib/sonbal-openai 0700 root root -"]

  preinst = File.read(File.join(control, "preinst"))
  fail!("preinst lost existing-identity validation") unless
    preinst.include?("pre-existing execution identity resolves to root") &&
      preinst.include?("pre-existing execution identity primary GID is root") &&
      preinst.include?("primary group is not sonbal") &&
      preinst.include?("pre-existing execution identity is not non-login")

  postinst = File.read(File.join(control, "postinst"))
  fail!("postinst lost activation-neutral OpenAI state bookkeeping") unless
    postinst.include?(
      "deb-systemd-helper update-state sonbal-openai.service"
    )
  fail!("postinst lost daemon-reload") unless
    postinst.include?("/usr/bin/systemctl --system daemon-reload")
  fail!("postinst lost package disclaimer display") unless
    postinst.include?("/usr/share/doc/sonbal/package-disclaimer.txt") &&
      postinst.include?('/bin/cat "$disclaimer"')
  fail!("postinst gained service activation") if
    postinst.include?("deb-systemd-invoke") ||
      postinst.match?(/systemctl .*\b(?:start|restart|enable)\b/)
  fail!("postinst disclaimer became interactive") if
    postinst.match?(/^\s*read\b/)

  prerm = File.read(File.join(control, "prerm"))
  [
    "deb-systemd-invoke stop sonbal-openai.service",
    "--property=ActiveState",
    "--property=MainPID",
    "--property=ControlGroup",
    "cgroup.events",
    "refusing package removal while service shutdown is incomplete"
  ].each do |token|
    fail!("prerm lost #{token.inspect}") unless prerm.include?(token)
  end

  postrm = File.read(File.join(control, "postrm"))
  [
    "deb-systemd-helper purge sonbal-openai.service",
    "/etc/systemd/system/multi-user.target.wants/sonbal-openai.service",
    "/usr/bin/systemctl --system daemon-reload"
  ].each do |token|
    fail!("postrm lost #{token.inspect}") unless postrm.include?(token)
  end

  lifecycle = [preinst, postinst, prerm, postrm].join("\n").downcase
  %w[fastcgi sonbal-tunnel tunnel-client nginx fasyn].each do |term|
    fail!("package lifecycle retained retired term #{term}") if
      lifecycle.include?(term)
  end
end

puts "[PASS] Debian connector-only package contents and lifecycle"
