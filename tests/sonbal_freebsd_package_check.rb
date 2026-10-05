#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_freebsd_package_check.rb
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
expected_mtime = Integer(ARGV.fetch(4), 10)
pkg = ARGV.fetch(5, "pkg")
readelf = ARGV.fetch(6, "/usr/bin/readelf")
repo_root = File.expand_path("..", __dir__)
tmp_root = File.join(repo_root, "build", "tmp")
FileUtils.mkdir_p(tmp_root)
expected_disclaimer = File.read(
  File.join(repo_root, "deployment", "package-disclaimer.txt"),
  encoding: "UTF-8"
).strip

def fail!(message)
  warn "[FAIL] #{message}"
  exit 1
end

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  fail!("#{command.join(' ')}: #{stderr.strip}") unless status.success?
  stdout
rescue Errno::ENOENT => error
  fail!("#{command.first}: #{error.message}")
end

def elf_section_names(readelf, executable)
  run!(readelf, "-S", "-W", executable).lines.filter_map do |line|
    match = line.match(/^\s*\[\s*\d+\]\s+(\S+)/)
    match[1] if match
  end
end

fail!("package artifact is missing") unless File.file?(artifact)
raw = run!(pkg, "info", "-F", artifact, "-R", "--raw-format", "json")
manifest = JSON.parse(raw)
manifest = manifest.first if manifest.is_a?(Array)
fail!("unexpected package name") unless manifest.fetch("name") == "sonbal"
fail!("unexpected package version") unless
  manifest.fetch("version") == expected_version
fail!("unexpected package prefix") unless manifest.fetch("prefix") == "/usr/local"
fail!("package ABI is not FreeBSD") unless
  manifest.fetch("abi").start_with?("FreeBSD:")
fail!("package license metadata is not exactly 0BSD") unless
  manifest.fetch("licenses") == ["0BSD"]
fail!("FreeBSD package disclaimer message changed") unless
  manifest.fetch("messages") == [{ "message" => expected_disclaimer }]

package_files = manifest.fetch("files")
expected_files = {
  "/usr/local/bin/sonbal" => "0555",
  "/usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so" => "0555",
  "/usr/local/etc/rc.d/sonbal_openai" => "0555",
  "/usr/local/etc/sonbal/sonbal.yaml.sample" => "0644",
  "/usr/local/etc/sonbal/openai.json.sample" => "0644",
  "/usr/local/share/sonbal/package-revisions" => "0644"
}
expected_files.each do |path, expected_mode|
  metadata = package_files[path]
  fail!("package manifest is missing #{path}") if metadata.nil?
  actual_mode = metadata.fetch("perm")
  fail!("package mode changed for #{path}: #{actual_mode}") unless
    actual_mode == expected_mode
  actual_mtime = Integer(metadata.fetch("mtime"))
  fail!("package mtime changed for #{path}: #{actual_mtime}") unless
    actual_mtime == expected_mtime
end
unexpected_files = package_files.keys - expected_files.keys
fail!("unexpected package payload: #{unexpected_files.join(', ')}") unless
  unexpected_files.empty?

scripts = manifest.fetch("scripts")
fail!("FreeBSD package must carry only pre-install identity setup") unless
  scripts.keys.sort == ["pre-install"]
pre_install = scripts.fetch("pre-install")
[
  "groupadd sonbal",
  "useradd sonbal -g sonbal",
  "execution identity unexpectedly resolves to root",
  "execution identity primary GID unexpectedly resolves to root",
  "execution identity is not non-login",
  "execution identity primary group is not sonbal"
].each do |token|
  fail!("FreeBSD identity setup lost #{token.inspect}") unless
    pre_install.include?(token)
end
fail!("pre-install retained external ingress state") if
  pre_install.match?(/sonbal-tunnel|tunnel-client|fastcgi|nginx|fasyn/i)
fail!("package scripts manage live services") if
  scripts.values.any? { |text| text.include?("/usr/sbin/service") }

deps = manifest.fetch("deps")
fail!("FreeBSD package must declare exactly one curl dependency") unless
  deps.is_a?(Hash) && deps.length == 1

Dir.mktmpdir("sonbal-freebsd-package-check-", tmp_root) do |dir|
  run!("/usr/bin/tar", "-xf", artifact, "-C", dir)
  root = File.join(dir, "usr", "local")

  expected_files.keys.each do |absolute|
    relative = absolute.delete_prefix("/usr/local/")
    fail!("package is missing #{relative}") unless
      File.file?(File.join(root, relative))
  end

  executable = File.join(root, "bin", "sonbal")
  executable_bytes = File.binread(executable)
  fail!("Sonbal executable embeds temporary package snapshot path") if
    executable_bytes.include?("sonbal-package-deps-")
  sections = elf_section_names(readelf, executable)
  fail!("Sonbal executable retains GPR linker metadata") if
    sections.include?(".GPR.linker_options")
  fail!("Sonbal executable retains nondeterministic GNU build ID") if
    sections.include?(".note.gnu.build-id")
  debug_sections = sections.grep(/\A\.(?:debug|zdebug)(?:_|\z)/)
  fail!("Sonbal executable retains debug sections") unless debug_sections.empty?

  connector = File.join(
    root, "lib", "sonbal", "connectors", "libsonbal_connector_openai.so"
  )
  connector_bytes = File.binread(connector)
  fail!("OpenAI connector embeds temporary package snapshot path") if
    connector_bytes.include?("sonbal-package-deps-")
  connector_dynamic = run!(readelf, "-d", connector)
  fail!("OpenAI connector lost libcurl runtime dependency") unless
    connector_dynamic.match?(/Shared library: \[libcurl\.so(?:\.[0-9]+)*\]/)
  connector_sections = elf_section_names(readelf, connector)
  fail!("OpenAI connector retains GPR linker metadata") if
    connector_sections.include?(".GPR.linker_options")
  fail!("OpenAI connector retains nondeterministic GNU build ID") if
    connector_sections.include?(".note.gnu.build-id")
  connector_debug = connector_sections.grep(/\A\.(?:debug|zdebug)(?:_|\z)/)
  fail!("OpenAI connector retains debug sections") unless connector_debug.empty?

  revisions = File.read(File.join(root, "share", "sonbal", "package-revisions"))
  values = revisions.lines.filter_map do |line|
    key, value = line.chomp.split("=", 2)
    [key, value] if key && value
  end.to_h
  expected = {
    "package_version" => expected_version,
    "sonbal_commit" => expected_sonbal,
    "clair_commit" => expected_clair,
    "sonbal_build_profile" => "release",
    "clair_build_profile" => "release"
  }
  expected.each do |key, value|
    fail!("package revision metadata mismatch for #{key}") unless
      values[key] == value
  end
  required_revision_keys =
    expected.keys + %w[
      sonbal_release curl_package_name curl_package_origin curl_package_version
    ]
  fail!("unexpected package revision metadata") unless
    values.keys.sort == required_revision_keys.sort

  curl_name = values.fetch("curl_package_name")
  curl_origin = values.fetch("curl_package_origin")
  curl_version = values.fetch("curl_package_version")
  fail!("package curl dependency name changed") unless curl_name == "curl"
  fail!("package curl dependency origin changed") unless curl_origin == "ftp/curl"
  fail!("package curl dependency differs from revision metadata") unless
    deps == {
      curl_name => {
        "origin" => curl_origin,
        "version" => curl_version
      }
    }

  openai_config = File.read(
    File.join(root, "etc", "sonbal", "openai.json.sample")
  )
  begin
    parsed_openai_config = JSON.parse(openai_config)
  rescue JSON::ParserError => error
    fail!("packaged OpenAI config is invalid JSON: #{error.message}")
  end
  fail!("packaged OpenAI config is not fail-closed by default") unless
    parsed_openai_config == { "tunnel_id" => "" }
  fail!("packaged OpenAI config gained secret-bearing state") if
    openai_config.match?(/credential|api[_-]?key|secret/i)

  openai_rc = File.read(File.join(root, "etc", "rc.d", "sonbal_openai"))
  [
    'state_dir="/var/db/sonbal-openai"',
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
    'retaining pidfiles because supervisor identity'
  ].each do |token|
    fail!("packaged OpenAI lifecycle lost #{token.inspect}") unless
      openai_rc.include?(token)
  end
  fail!("packaged OpenAI service gained automatic restart") if
    openai_rc.include?('"$daemon_command" -r') ||
      openai_rc.include?('"$daemon_command" -R')
  fail!("packaged OpenAI lifecycle retained external ingress") if
    openai_rc.match?(/fastcgi|tunnel-client|nginx|fasyn/i)
end

puts "[PASS] FreeBSD connector-only package artifact #{File.basename(artifact)}"
