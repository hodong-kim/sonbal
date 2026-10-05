# =============================================================================
# Rakefile
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"

BUILD_DIR = "build"
PACKAGE_BUILD_ROOT = File.expand_path(BUILD_DIR, __dir__)
CLAIR_DEPENDENCY_BUILD_ROOT = File.join(PACKAGE_BUILD_ROOT, "deps", "clair")
PACKAGE_TMP_ROOT = File.join(PACKAGE_BUILD_ROOT, "tmp")
PRODUCT_PROJECT = "sonbal.gpr"
TEST_PROJECT = File.join("tests", "sonbal_tests.gpr")
STDIO_FIXTURE_PROJECT = File.join("tests", "sonbal_stdio_server_fixture.gpr")
CONNECTOR_HOST_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_host_fixture.gpr")
CONNECTOR_SERVER_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_server_fixture.gpr")
CONNECTOR_FAKE_PLUGIN_PROJECT =
  File.join("tests", "sonbal_connector_fake_plugin.gpr")
CONNECTOR_BAD_ABI_PROJECT =
  File.join("tests", "sonbal_connector_bad_abi.gpr")
CONNECTOR_MISSING_SYMBOL_PROJECT =
  File.join("tests", "sonbal_connector_missing_symbol.gpr")
OPENAI_CONNECTOR_PROJECT = "sonbal_connector_openai.gpr"
OPENAI_PROTOCOL_TEST_PROJECT =
  File.join("tests", "sonbal_connector_openai_protocol_test.gpr")
OPENAI_CONNECTOR_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_openai_fixture.gpr")
OPENAI_HTTP_TEST_PROJECT =
  File.join("tests", "sonbal_connector_openai_http_test.gpr")
OPENAI_TRANSPORT_TEST_PROJECT =
  File.join("tests", "sonbal_connector_openai_transport_test.gpr")
OPENAI_RUNTIME_PLUGIN_PROJECT =
  File.join("tests", "sonbal_connector_openai_runtime_plugin.gpr")
OPENAI_RUNTIME_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_openai_runtime_fixture.gpr")
CONNECTOR_SERVICE_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_service_fixture.gpr")
OPENAI_E2E_FIXTURE_PROJECT =
  File.join("tests", "sonbal_connector_openai_e2e_fixture.gpr")
CLAIR_TIMER_CHURN_FIXTURE_PROJECT =
  File.join("tests", "sonbal_clair_timer_churn_fixture.gpr")
CLAIR_WATCH_CHURN_FIXTURE_PROJECT =
  File.join("tests", "sonbal_clair_watch_churn_fixture.gpr")
ADA_PROTECTED_CONTEXT_CHURN_FIXTURE_PROJECT =
  File.join("tests", "sonbal_ada_protected_context_churn_fixture.gpr")
CLAIR_PROCESS_FIXTURE_PROJECT = File.join("tests", "clair_process_fixture.gpr")
GPRBUILD = ENV.fetch("GPRBUILD", "gprbuild")
RAKE = ENV.fetch("RAKE", "rake")
GIT = ENV.fetch("GIT", "git")
EXECUTABLE_SUFFIX = RbConfig::CONFIG.fetch("EXEEXT")
INTEGRATION_TEST = File.join("tests", "sonbal_stdio_integration.rb")
STDIO_SIGNAL_INTEGRATION_TEST =
  File.join("tests", "sonbal_stdio_signal_integration.rb")
CONNECTOR_HOST_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_host_integration.rb")
CONNECTOR_SERVER_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_server_integration.rb")
OPENAI_CONNECTOR_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_integration.rb")
OPENAI_HTTP_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_http_integration.rb")
OPENAI_TRANSPORT_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_transport_integration.rb")
OPENAI_RUNTIME_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_runtime_integration.rb")
CONNECTOR_SERVICE_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_service_integration.rb")
OPENAI_E2E_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_e2e_integration.rb")
OPENAI_FAILURE_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_failure_integration.rb")
OPENAI_STABILITY_INTEGRATION_TEST =
  File.join("tests", "sonbal_connector_openai_stability_integration.rb")
CLAIR_TIMER_CHURN_DIAGNOSTIC = File.join(
  "tests", "sonbal_clair_timer_churn.rb"
)
CLAIR_WATCH_CHURN_DIAGNOSTIC = File.join(
  "tests", "sonbal_clair_watch_churn.rb"
)
ADA_PROTECTED_CONTEXT_CHURN_DIAGNOSTIC = File.join(
  "tests", "sonbal_ada_protected_context_churn.rb"
)
CHATGPT_JOB_PROBE = File.join(
  "tests", "sonbal_chatgpt_job_probe.rb"
)
LINUX_DEPLOYMENT_CHECK = File.join(
  "tests", "sonbal_linux_deployment_check.rb"
)
LINUX_OPENAI_SERVICE_UNIT = File.join(
  "deployment", "linux", "systemd", "sonbal-openai.service"
)
LINUX_TMPFILES_CONFIG = File.join(
  "deployment", "linux", "tmpfiles", "sonbal.conf"
)
LINUX_SYSUSERS_CONFIG = File.join(
  "deployment", "linux", "sysusers", "sonbal.conf"
)
LINUX_DEFAULT_CONFIG = File.join(
  "deployment", "linux", "config", "sonbal.yaml"
)
LINUX_OPENAI_CONFIG = File.join(
  "deployment", "linux", "config", "openai.json"
)
DEBIAN_RULES = File.join("debian", "rules")
DEBIAN_CONTROL = File.join("debian", "control")
DEBIAN_PREINST = File.join("debian", "sonbal.preinst")
DEBIAN_POSTINST = File.join("debian", "sonbal.postinst")
DEBIAN_PRERM = File.join("debian", "sonbal.prerm")
DEBIAN_POSTRM = File.join("debian", "sonbal.postrm")
LINUX_PLATFORM_CONFIG = File.join(
  "src", "platform", "linux", "sonbal-platform_config.ads"
)
RAKE_ORCHESTRATION_CHECK = File.join(
  "tests", "sonbal_rake_orchestration_check.rb"
)
SOURCE_CONTRACT_CHECK = File.join(
  "tests", "sonbal_source_contract_check.rb"
)
FREEBSD_DEPLOYMENT_CHECK = File.join(
  "tests", "sonbal_freebsd_deployment_check.rb"
)
FREEBSD_OPENAI_RC = File.join(
  "deployment", "freebsd", "rc.d", "sonbal_openai"
)
FREEBSD_DEFAULT_CONFIG = File.join(
  "deployment", "freebsd", "config", "sonbal.yaml"
)
FREEBSD_OPENAI_CONFIG = File.join(
  "deployment", "freebsd", "config", "openai.json"
)
PACKAGE_DISCLAIMER = File.join("deployment", "package-disclaimer.txt")
FREEBSD_PLATFORM_CONFIG = File.join(
  "src", "platform", "freebsd", "sonbal-platform_config.ads"
)
DEBIAN_CHANGELOG = File.join("debian", "changelog")
DEBIAN_PACKAGE_METADATA = File.join(
  BUILD_DIR, "package", "sonbal-revisions"
)
DEBIAN_PACKAGE_CHECK = File.join(
  "tests", "sonbal_debian_package_check.rb"
)
DEBIAN_INSTALLED_CHECK = File.join(
  "tests", "sonbal_debian_installed_check.rb"
)
LINUX_OPENAI_SERVICE_CHECK = File.join(
  "tests", "sonbal_linux_openai_service_check.rb"
)
DPKG_BUILDPACKAGE = ENV.fetch("DPKG_BUILDPACKAGE", "dpkg-buildpackage")
DPKG_PARSECHANGELOG = ENV.fetch("DPKG_PARSECHANGELOG", "dpkg-parsechangelog")
FREEBSD_PACKAGE_CHECK = File.join(
  "tests", "sonbal_freebsd_package_check.rb"
)
FREEBSD_INSTALLED_CHECK = File.join(
  "tests", "sonbal_freebsd_installed_check.rb"
)
FREEBSD_OPENAI_SERVICE_CHECK = File.join(
  "tests", "sonbal_freebsd_openai_service_check.rb"
)
FREEBSD_PACKAGE_PLIST = File.join("freebsd", "pkg-plist")
FREEBSD_PRE_INSTALL = File.join("freebsd", "scripts", "pre-install")
PKG = ENV.fetch("PKG", "/usr/local/sbin/pkg")
OBJCOPY = ENV.fetch("OBJCOPY", "objcopy")
READELF = ENV.fetch("READELF", "/usr/bin/readelf")
SONBAL_BUILD_PROFILE = ENV.fetch("SONBAL_BUILD_PROFILE", "debug")
SONBAL_LICENSE_ID = "0BSD"
ADA_SOURCE_GLOB = "{src,tests}/**/*.{adb,ads}"
ADA_SOURCE_HEADER_SEPARATOR = "-- #{'=' * 76}"
ADA_SOURCE_COPYRIGHT = "-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>"
ADA_SOURCE_LICENSE = "-- SPDX-License-Identifier: #{SONBAL_LICENSE_ID}"
RUBY_SOURCE_GLOB = "tests/**/*.rb"
HASH_SOURCE_HEADER_SEPARATOR = "# #{'=' * 77}"
HASH_SOURCE_COPYRIGHT = "# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>"
HASH_SOURCE_LICENSE = "# SPDX-License-Identifier: #{SONBAL_LICENSE_ID}"
GPR_SOURCE_GLOB = "{sonbal*.gpr,tests/**/*.gpr}"
HASH_HEADER_FILES = %w[
  Rakefile
  debian/rules
  debian/sonbal.postinst
  debian/sonbal.postrm
  debian/sonbal.preinst
  debian/sonbal.prerm
  deployment/freebsd/config/sonbal.yaml
  deployment/freebsd/rc.d/sonbal_openai
  deployment/linux/config/sonbal.yaml
  deployment/linux/systemd/sonbal-openai.service
  deployment/linux/sysusers/sonbal.conf
  deployment/linux/tmpfiles/sonbal.conf
  freebsd/scripts/pre-install
].freeze
RELEASE_IDENTITY_SOURCE = File.join("src", "sonbal-release_identity.ads")


def release_identity_source(version, revision)
  <<~ADA
    #{ADA_SOURCE_HEADER_SEPARATOR}
    -- sonbal-release_identity.ads
    #{ADA_SOURCE_COPYRIGHT}
    #{ADA_SOURCE_LICENSE}
    #{ADA_SOURCE_HEADER_SEPARATOR}

    package Sonbal.Release_Identity is
      --! summary Release date identifier in `YYYY.MM.DD` form.
      Version : constant String := "#{version}";

      --! summary Release revision identifier in `HHMMSS` form.
      Revision : constant String := "#{revision}";
    end Sonbal.Release_Identity;
  ADA
end


def release_identity
  unless File.file?(RELEASE_IDENTITY_SOURCE)
    abort "missing Sonbal release identity: #{RELEASE_IDENTITY_SOURCE}"
  end

  source = File.read(RELEASE_IDENTITY_SOURCE, encoding: "UTF-8")
  version = source[/^\s*Version\s*:\s*constant\s+String\s*:=\s*"([^"]+)";/, 1]
  revision =
    source[/^\s*Revision\s*:\s*constant\s+String\s*:=\s*"([^"]+)";/, 1]

  if version.nil? || revision.nil?
    abort "invalid Sonbal release identity source: #{RELEASE_IDENTITY_SOURCE}"
  end

  unless version.match?(/\A\d{4}\.\d{2}\.\d{2}\z/)
    abort "invalid Sonbal release version: #{version.inspect}"
  end

  begin
    Date.strptime(version, "%Y.%m.%d")
  rescue Date::Error
    abort "invalid Sonbal release date: #{version.inspect}"
  end

  unless revision.match?(/\A\d{6}\z/)
    abort "invalid Sonbal release revision: #{revision.inspect}"
  end

  hour = Integer(revision[0, 2], 10)
  minute = Integer(revision[2, 2], 10)
  second = Integer(revision[4, 2], 10)
  unless hour.between?(0, 23) &&
         minute.between?(0, 59) &&
         second.between?(0, 59)
    abort "invalid Sonbal release time: #{revision.inspect}"
  end

  [version, revision]
end


def debian_package_version(version, revision)
  "#{version}+#{revision}"
end


def freebsd_package_version(version, revision)
  "#{version}.#{revision}"
end


def freebsd_pkg_config(key)
  capture_command(PKG, "config", key)
end


def freebsd_installed_package(name)
  fields = capture_command(PKG, "query", "%n\t%o\t%v", name).split("\t", -1)
  if fields.length != 3 || fields.fetch(0) != name ||
     fields.drop(1).any?(&:empty?)
    abort "invalid installed FreeBSD package metadata for #{name}"
  end

  {
    "name" => fields.fetch(0),
    "origin" => fields.fetch(1),
    "version" => fields.fetch(2)
  }
end


def freebsd_package_artifact!
  artifacts = Dir.glob(
    File.join(BUILD_DIR, "package", "freebsd", "sonbal-*.pkg")
  ).sort
  abort "expected exactly one Sonbal FreeBSD package artifact" unless
    artifacts.length == 1
  artifacts.fetch(0)
end


def freebsd_artifact_revision_metadata(artifact)
  text = capture_command(
    "/usr/bin/tar", "-xOf", artifact,
    "/usr/local/share/sonbal/package-revisions"
  )
  values = text.lines.filter_map do |line|
    key, value = line.chomp.split("=", 2)
    [key, value] if key && value
  end.to_h
  required = %w[
    package_version sonbal_commit clair_commit
    curl_package_name curl_package_origin curl_package_version
  ]
  missing = required.reject { |key| values.key?(key) && !values[key].empty? }
  abort "FreeBSD package revision metadata is missing #{missing.join(', ')}" unless
    missing.empty?
  values
end


def debian_changelog_source(version, revision, timestamp)
  <<~CHANGELOG
    sonbal (#{debian_package_version(version, revision)}) unstable; urgency=medium

      * Build Sonbal release #{version}-#{revision}.

     -- Hodong Kim <hodong@nimfsoft.com>  #{timestamp.rfc2822}
  CHANGELOG
end


def sonbal_commit
  capture_command(GIT, "rev-parse", "HEAD", chdir: __dir__)
end


def git_commit_epoch(root, commit)
  raw = capture_command(GIT, "-C", root, "show", "-s", "--format=%ct", commit)
  Integer(raw, 10)
rescue ArgumentError
  abort "invalid commit timestamp for #{commit}: #{raw.inspect}"
end


def clone_committed_checkout(source, target, expected_commit)
  sh GIT, "clone", "--quiet", "--no-tags", "--no-hardlinks", source, target
  sh GIT, "-C", target, "checkout", "--quiet", "--detach", expected_commit
  actual = capture_command(GIT, "-C", target, "rev-parse", "HEAD")
  abort "failed to materialize package snapshot #{expected_commit}: #{source}" unless
    actual == expected_commit
end


def with_package_tmpdir(prefix)
  tmp_stat = prepare_package_workspace_root

  Dir.mktmpdir(prefix, PACKAGE_TMP_ROOT) do |dir|
    actual_gid = File.stat(dir).gid
    abort "package temporary workspace did not inherit build/tmp group" unless
      actual_gid == tmp_stat.gid
    File.chmod(0o2770, dir)
    yield dir
  end
end


def shared_package_directory_stat(path, label)
  stat = File.lstat(path)
  abort "#{label} must not be a symlink" if stat.symlink?
  abort "#{label} is not a directory" unless stat.directory?
  mode = stat.mode & 0o7777
  group_write_error = "#{label} is not group writable: #{path} " \
    "mode=#{format("%04o", mode)}"
  abort group_write_error if (mode & 0o0020).zero?
  abort "#{label} is not setgid: #{path} mode=#{format("%04o", mode)}" if
    (mode & 0o2000).zero?
  world_write_error = "#{label} is world writable: #{path} " \
    "mode=#{format("%04o", mode)}"
  abort world_write_error unless (mode & 0o0002).zero?
  stat
rescue Errno::ENOENT
  abort "#{label} is missing: #{path}"
end


def create_shared_package_directory(path, label, expected_gid)
  created = false
  unless File.exist?(path) || File.symlink?(path)
    Dir.mkdir(path, 0o2775)
    File.chmod(0o2775, path)
    created = true
  end

  stat = shared_package_directory_stat(path, label)
  if created && stat.uid != Process.euid
    abort "#{label} owner changed during creation"
  end
  abort "#{label} did not inherit expected group" unless stat.gid == expected_gid
  stat
end


def prepare_package_workspace_root
  repository_gid = File.stat(__dir__).gid
  build_stat = create_shared_package_directory(
    PACKAGE_BUILD_ROOT, "build root", repository_gid
  )
  create_shared_package_directory(
    PACKAGE_TMP_ROOT, "package temporary root", build_stat.gid
  )
end


def prepare_package_artifact_dir(path)
  build_stat = prepare_package_workspace_root
  build_root = PACKAGE_BUILD_ROOT
  package_root = File.join(build_root, "package")

  package_stat = create_shared_package_directory(
    package_root, "package artifact root", build_stat.gid
  )
  abort "package artifact path escaped package root" unless
    File.dirname(File.expand_path(path)) == package_root

  if File.exist?(path) || File.symlink?(path)
    existing = File.lstat(path)
    abort "package artifact directory must not be a symlink" if
      existing.symlink?
    abort "package artifact path is not a directory" unless existing.directory?
    abort "package artifact directory group changed" unless
      existing.gid == package_stat.gid
  end

  rm_rf path
  mkdir_p path
  File.chmod(0o2775, path)
  actual = shared_package_directory_stat(path, "package artifact directory")
  abort "package artifact directory owner changed" unless
    actual.uid == Process.euid
  abort "package artifact directory did not inherit package group" unless
    actual.gid == package_stat.gid
end


def with_package_dependency_snapshot
  source_clair = clair_root
  expected_clair = clair_commit(source_clair)

  with_package_tmpdir("sonbal-package-deps-") do |dir|
    clair = File.join(dir, "clair")
    clone_committed_checkout(source_clair, clair, expected_clair)
    yield clair, expected_clair
  end
end


def verify_sonbal_package_checkout
  dirty = capture_command(
    GIT, "status", "--porcelain", "--untracked-files=no", chdir: __dir__
  )
  abort "Sonbal checkout has tracked modifications:\n#{dirty}" unless dirty.empty?
end


def verify_artifact(path)
  return if File.file?(path)

  abort "expected build artifact was not created: #{path}"
end


def sanitize_packaged_executable(path)
  sh OBJCOPY, "--strip-debug",
     "--remove-section=.GPR.linker_options",
     "--remove-section=.note.gnu.build-id",
     path
end


def capture_command(*command, environment: {}, chdir: nil)
  options = {}
  options[:chdir] = chdir if chdir
  stdout, stderr, status = Open3.capture3(environment, *command, **options)
  return stdout.strip if status.success?

  abort "command failed: #{command.join(" ")}\n#{stderr}"
end


def clair_checkout_candidates
  explicit = ENV["CLAIR_ROOT"]
  unless explicit.nil? || explicit.empty?
    return [File.expand_path(explicit, __dir__)]
  end

  %w[../clair ../clair-private ../ada-clair].map do |path|
    File.expand_path(path, __dir__)
  end
end


def clair_root
  return @clair_root if @clair_root

  @clair_root = clair_checkout_candidates.find do |candidate|
    File.file?(File.join(candidate, "LICENSE")) &&
      File.file?(File.join(candidate, "Rakefile")) &&
      File.file?(File.join(candidate, "clair.gpr")) &&
      File.file?(File.join(candidate, "clair_config.gpr")) &&
      File.file?(File.join(candidate, "src", "clair-random.ads")) &&
      File.file?(File.join(candidate, "src", "clair-io.ads")) &&
      File.file?(File.join(candidate, "src", "clair-status.ads")) &&
      File.file?(File.join(
        candidate, "src", "event_loop", "clair-event_loop.ads")) &&
      File.file?(File.join(candidate, "src", "unix", "clair-unix-signal.ads"))
  end
  return @clair_root if @clair_root

  abort <<~MESSAGE
    Clair checkout was not found.
    Set CLAIR_ROOT or place Clair in one of these sibling directories:
      #{clair_checkout_candidates.join("\n  ")}
  MESSAGE
end


def clair_command_environment
  environment = {
    "CLAIR_BUILD_ROOT" => CLAIR_DEPENDENCY_BUILD_ROOT
  }
  unless ENV.key?("CLAIR_BUILD_PROFILE") || ENV.key?("PROFILE")
    environment["CLAIR_BUILD_PROFILE"] = "debug"
  end
  environment
end


def clair_commit(root)
  capture_command(GIT, "-C", root, "rev-parse", "HEAD")
end


def verify_clair_checkout(root)
  required_files = [
    File.join(root, "LICENSE"),
    File.join(root, "Rakefile"),
    File.join(root, "clair.gpr"),
    File.join(root, "clair_config.gpr"),
    File.join(root, "src", "clair-random.ads"),
    File.join(root, "src", "clair-io.ads"),
    File.join(root, "src", "clair-status.ads"),
    File.join(
      root, "src", "event_loop", "clair-event_loop.ads"),
    File.join(root, "src", "unix", "clair-unix-signal.ads")
  ]
  required_files.each do |path|
    abort "required Clair file is missing: #{path}" unless File.file?(path)
  end

  dirty_paths = capture_command(
    GIT,
    "-C",
    root,
    "status",
    "--porcelain",
    "--untracked-files=no"
  )
  unless dirty_paths.empty?
    abort "Clair checkout has tracked modifications:\n#{dirty_paths}"
  end

  license_text = File.read(File.join(root, "LICENSE"), encoding: "UTF-8")
  unless license_text.include?("Zero-Clause BSD License (0BSD)")
    abort "Clair license no longer matches the recorded 0BSD dependency"
  end
end


def clair_build_context(root)
  values = capture_command(
    RAKE,
    "info",
    environment: clair_command_environment,
    chdir: root
  ).lines.filter_map do |line|
    key, value = line.strip.split("=", 2)
    [key, value] if key && value
  end.to_h

  required = %w[
    CLAIR_BUILD_ROOT
    HOST_TARGET
    HOST_OS
    CLAIR_TARGET
    CLAIR_TARGET_OS
    CLAIR_TARGET_ABI
    CLAIR_PROJECT_VERSION
    CLAIR_BUILD_PROFILE
    CLAIR_ARTIFACT_PROFILE
    CLAIR_SECURITY_INSTRUMENTATION
    CLAIR_LIBRARY_TYPE
    NATIVE_TARGET
  ]
  missing = required.reject { |key| values.key?(key) }
  unless missing.empty?
    abort "Clair build context is missing: #{missing.join(", ")}"
  end

  actual_build_root = File.expand_path(values.fetch("CLAIR_BUILD_ROOT"))
  unless actual_build_root == CLAIR_DEPENDENCY_BUILD_ROOT
    message = "Clair build root #{actual_build_root} does not match " \
              "#{CLAIR_DEPENDENCY_BUILD_ROOT}"
    abort message
  end

  values
end


def prepare_clair_production_library(root)
  Dir.chdir(root) do
    sh clair_command_environment, RAKE, "build"
  end
end


def current_clair_context
  @current_clair_context ||= clair_build_context(clair_root)
end


def sonbal_product_artifact_profile
  context = current_clair_context
  "#{SONBAL_BUILD_PROFILE}-clair-" \
    "#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-" \
    "#{context.fetch("CLAIR_LIBRARY_TYPE")}"
end


def sonbal_test_artifact_profile
  context = current_clair_context
  "test-clair-#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-" \
    "#{context.fetch("CLAIR_LIBRARY_TYPE")}"
end


def product_executable(
  context = current_clair_context,
  build_root: PACKAGE_BUILD_ROOT,
  build_profile: SONBAL_BUILD_PROFILE
)
  profile =
    "#{build_profile}-clair-#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-" \
    "#{context.fetch("CLAIR_LIBRARY_TYPE")}"
  File.join(
    build_root,
    "bin",
    context.fetch("CLAIR_TARGET"),
    profile,
    "sonbal#{EXECUTABLE_SUFFIX}"
  )
end


def product_connector_library(
  name,
  context = current_clair_context,
  build_root: PACKAGE_BUILD_ROOT,
  build_profile: SONBAL_BUILD_PROFILE
)
  profile =
    "#{build_profile}-clair-#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-" \
    "#{context.fetch("CLAIR_LIBRARY_TYPE")}"
  File.join(
    build_root,
    "bin",
    context.fetch("CLAIR_TARGET"),
    profile,
    "connectors",
    "lib#{name}.#{RbConfig::CONFIG.fetch("DLEXT")}"
  )
end


def test_executable(name, context = current_clair_context)
  File.join(
    PACKAGE_BUILD_ROOT,
    "bin",
    context.fetch("CLAIR_TARGET"),
    "test-clair-#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-" \
      "#{context.fetch("CLAIR_LIBRARY_TYPE")}",
    "tests",
    "#{name}#{EXECUTABLE_SUFFIX}"
  )
end


def test_library(name, context = current_clair_context)
  File.join(
    PACKAGE_BUILD_ROOT,
    "bin",
    context.fetch("CLAIR_TARGET"),
    "test-clair-#{context.fetch("CLAIR_ARTIFACT_PROFILE")}-"       "#{context.fetch("CLAIR_LIBRARY_TYPE")}",
    "tests",
    "#{RbConfig::CONFIG.fetch("DLEXT").empty? ? "lib" : "lib"}#{name}."       "#{RbConfig::CONFIG.fetch("DLEXT")}"
  )
end


def clair_process_fixture_executable(context = current_clair_context)
  File.join(
    CLAIR_DEPENDENCY_BUILD_ROOT,
    "bin",
    context.fetch("CLAIR_TARGET"),
    context.fetch("CLAIR_ARTIFACT_PROFILE"),
    "clair-process-fixture#{EXECUTABLE_SUFFIX}"
  )
end


def native_target?(context)
  context.fetch("NATIVE_TARGET") == "true"
end


def ensure_native_target!(context = current_clair_context)
  return if native_target?(context)

  abort(
    "cannot execute target #{context.fetch("CLAIR_TARGET")} on " \
    "build host #{context.fetch("HOST_TARGET")}; use a build-only task"
  )
end


def native_product_executable(context = current_clair_context)
  ensure_native_target!(context)
  product_executable(context)
end


def native_test_executable(name, context = current_clair_context)
  ensure_native_target!(context)
  test_executable(name, context)
end


def sonbal_project_arguments
  [
    "-aP#{__dir__}",
    "-XSONBAL_BUILD_PROFILE=#{SONBAL_BUILD_PROFILE}"
  ]
end


def clair_project_arguments(root, context)
  arguments = [
    "-p",
    "-s",
    "-aP#{root}",
    "-XCLAIR_BUILD_ROOT=#{CLAIR_DEPENDENCY_BUILD_ROOT}",
    "-XCLAIR_ARTIFACT_PROFILE=#{context.fetch("CLAIR_ARTIFACT_PROFILE")}",
    "-XCLAIR_SECURITY_INSTRUMENTATION=" \
      "#{context.fetch("CLAIR_SECURITY_INSTRUMENTATION")}",
    "-XCLAIR_LIBRARY_TYPE=#{context.fetch("CLAIR_LIBRARY_TYPE")}",
    "-XCLAIR_CORE_EXTERNALLY_BUILT=True"
  ]

  gpr_target = context["CLAIR_GPR_TARGET"]
  arguments << "--target=#{gpr_target}" if gpr_target && !gpr_target.empty?

  %w[
    CLAIR_TARGET
    CLAIR_TARGET_OS
    CLAIR_PROJECT_VERSION
    CLAIR_BUILD_PROFILE
    CLAIR_C_COMPILER
    CLAIR_CLANG_TARGET
    CLAIR_TARGET_SYSROOT
    CLAIR_LIBYAML_PREFIX
    CLAIR_PCRE2_PREFIX
    CLAIR_GETTEXT_PREFIX
  ].each do |key|
    value = context[key]
    arguments << "-X#{key}=#{value}" if value && !value.empty?
  end

  arguments
end


desc "Show the resolved build configuration"
task :info do
  version, revision = release_identity
  root = clair_root
  context = clair_build_context(root)

  puts "GPRBUILD=#{GPRBUILD}"
  puts "product project=#{PRODUCT_PROJECT}"
  puts "test project=#{TEST_PROJECT}"
  puts "Sonbal build root=#{PACKAGE_BUILD_ROOT}"
  puts "Clair build root=#{CLAIR_DEPENDENCY_BUILD_ROOT}"
  puts "product artifact profile=#{sonbal_product_artifact_profile}"
  puts "test artifact profile=#{sonbal_test_artifact_profile}"
  puts "product executable=#{product_executable(context)}"
  puts "test executable=#{test_executable("sonbal-tests", context)}"
  puts "Sonbal version=#{version}"
  puts "Sonbal revision=#{revision}"
  puts "Clair root=#{root}"
  puts "Clair commit=#{clair_commit(root)}"
  puts "Clair target=#{context.fetch("CLAIR_TARGET")}"
  puts "Clair target OS=#{context.fetch("CLAIR_TARGET_OS")}"
  puts "Clair target ABI=#{context.fetch("CLAIR_TARGET_ABI")}"
  puts "Build host=#{context.fetch("HOST_TARGET")}"
  puts "Native target=#{context.fetch("NATIVE_TARGET")}"
  puts "Clair profile=#{context.fetch("CLAIR_BUILD_PROFILE")}"
  puts "Sonbal profile=#{SONBAL_BUILD_PROFILE}"
  sh GPRBUILD, "--version"
end


desc "Check source/document MCP contract consistency"
task :"source-contract-check" do
  unless File.file?(SOURCE_CONTRACT_CHECK)
    abort "Source contract check is missing"
  end
  sh RbConfig.ruby, SOURCE_CONTRACT_CHECK
end


desc "Check first-party source and license policy"
task :policy => :"source-contract-check" do
  release_identity
  violations = []

  Dir.glob(ADA_SOURCE_GLOB).sort.each do |path|
    expected_header = [
      ADA_SOURCE_HEADER_SEPARATOR,
      "-- #{File.basename(path)}",
      ADA_SOURCE_COPYRIGHT,
      ADA_SOURCE_LICENSE,
      ADA_SOURCE_HEADER_SEPARATOR,
      ""
    ]
    actual_header = File.readlines(path, chomp: true).first(expected_header.length)
    unless actual_header == expected_header
      violations << "#{path}: invalid Sonbal Ada source header"
    end

    File.foreach(path).with_index(1) do |line, line_number|
      next unless line.match?(/\bGNAT\./i)

      violations << "#{path}:#{line_number}: #{line.rstrip}"
    end
  end

  Dir.glob(RUBY_SOURCE_GLOB).sort.each do |path|
    lines = File.readlines(path, chomp: true)
    header_index = 0
    header_index += 1 if lines.fetch(header_index, "").start_with?("#!")
    if lines.fetch(header_index, "").start_with?("# frozen_string_literal:")
      header_index += 1
    end
    expected_header = [
      HASH_SOURCE_HEADER_SEPARATOR,
      "# #{File.basename(path)}",
      HASH_SOURCE_COPYRIGHT,
      HASH_SOURCE_LICENSE,
      HASH_SOURCE_HEADER_SEPARATOR,
      ""
    ]
    actual_header = lines.slice(header_index, expected_header.length)
    unless actual_header == expected_header
      violations << "#{path}: invalid Sonbal Ruby source header"
    end
  end

  Dir.glob(GPR_SOURCE_GLOB).sort.each do |path|
    expected_header = [
      ADA_SOURCE_HEADER_SEPARATOR,
      "-- #{File.basename(path)}",
      ADA_SOURCE_COPYRIGHT,
      ADA_SOURCE_LICENSE,
      ADA_SOURCE_HEADER_SEPARATOR,
      ""
    ]
    actual_header = File.readlines(path, chomp: true).first(expected_header.length)
    unless actual_header == expected_header
      violations << "#{path}: invalid Sonbal GPR source header"
    end
  end

  HASH_HEADER_FILES.each do |path|
    lines = File.readlines(path, chomp: true)
    header_index = lines.fetch(0, "").start_with?("#!") ? 1 : 0
    expected_header = [
      HASH_SOURCE_HEADER_SEPARATOR,
      "# #{File.basename(path)}",
      HASH_SOURCE_COPYRIGHT,
      HASH_SOURCE_LICENSE,
      HASH_SOURCE_HEADER_SEPARATOR,
      ""
    ]
    actual_header = lines.slice(header_index, expected_header.length)
    unless actual_header == expected_header
      violations << "#{path}: invalid Sonbal hash-comment source header"
    end
  end

  license = File.read("LICENSE", encoding: "UTF-8")
  license_lines = license.lines(chomp: true)
  unless license_lines.fetch(0, "") == "Zero-Clause BSD" &&
         license_lines.fetch(1, "") == ("=" * 15) &&
         license.include?("Permission to use, copy, modify, and/or distribute") &&
         license.include?("THE SOFTWARE IS PROVIDED “AS IS”")
    violations << "LICENSE: invalid Sonbal 0BSD license text"
  end

  debian_copyright = File.read("debian/copyright", encoding: "UTF-8")
  unless debian_copyright.include?("License: #{SONBAL_LICENSE_ID}") &&
         !debian_copyright.match?(/\bProprietary\b/i)
    violations << "debian/copyright: invalid Sonbal 0BSD package metadata"
  end

  svg = File.read("assets/sonbal.svg", encoding: "UTF-8")
  unless svg.include?("SPDX-License-Identifier: #{SONBAL_LICENSE_ID}") &&
         svg.include?("Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>")
    violations << "assets/sonbal.svg: invalid Sonbal 0BSD asset header"
  end

  unless violations.empty?
    abort "Sonbal source policy violations:\n#{violations.join("\n")}"
  end
end


desc "Update the tracked Sonbal release identity from local system time"
task :"bump-version" do
  now = Time.now.getlocal
  version = now.strftime("%Y.%m.%d")
  revision = now.strftime("%H%M%S")

  File.open(RELEASE_IDENTITY_SOURCE, "w:UTF-8") do |file|
    file.write(release_identity_source(version, revision))
  end
  if Dir.exist?("debian")
    File.open(DEBIAN_CHANGELOG, "w:UTF-8") do |file|
      file.write(debian_changelog_source(version, revision, now))
    end
  end

  puts "Sonbal release identity=#{version}-#{revision}"
end


desc "Build the Sonbal executable"
task build: :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)

  puts "Clair root=#{root}"
  puts "Clair commit=#{clair_commit(root)}"
  puts "Clair target=#{context.fetch("CLAIR_TARGET")}"
  puts "Clair target OS=#{context.fetch("CLAIR_TARGET_OS")}"
  puts "Clair profile=#{context.fetch("CLAIR_BUILD_PROFILE")}"

  prepare_clair_production_library(root)
  unless %w[debug release].include?(SONBAL_BUILD_PROFILE)
    abort "invalid Sonbal build profile: #{SONBAL_BUILD_PROFILE.inspect}"
  end
  gprbuild_switches = []
  gprbuild_switches << "-R" if SONBAL_BUILD_PROFILE == "release"
  sh GPRBUILD,
     *gprbuild_switches,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     PRODUCT_PROJECT
  sh GPRBUILD,
     *gprbuild_switches,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_CONNECTOR_PROJECT
  verify_artifact(product_executable(context))
  verify_artifact(
    product_connector_library("sonbal_connector_openai", context)
  )
end


desc "Stage the current Sonbal product artifacts for Debian packaging"
task :"debian-stage-binary" => :policy do
  context = current_clair_context
  executable = product_executable(context)
  connector = product_connector_library("sonbal_connector_openai", context)
  verify_artifact(executable)
  verify_artifact(connector)

  binary_destination = File.join("debian", "sonbal", "usr", "bin")
  connector_destination = File.join(
    "debian", "sonbal", "usr", "lib", "sonbal", "connectors"
  )
  mkdir_p binary_destination
  mkdir_p connector_destination
  cp executable, File.join(binary_destination, "sonbal")
  cp connector, File.join(
    connector_destination, "libsonbal_connector_openai.so"
  )
end


desc "Write exact Debian package revision metadata"
task :"debian-package-metadata" => :policy do
  verify_sonbal_package_checkout
  version, revision = release_identity
  expected = debian_package_version(version, revision)
  actual = capture_command(DPKG_PARSECHANGELOG, "-SVersion")
  abort "Debian changelog version #{actual} does not match #{expected}" unless
    actual == expected

  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  mkdir_p File.dirname(DEBIAN_PACKAGE_METADATA)
  File.write(
    DEBIAN_PACKAGE_METADATA,
    <<~METADATA
      package_version=#{expected}
      sonbal_release=#{version}-#{revision}
      sonbal_commit=#{sonbal_commit}
      sonbal_build_profile=#{SONBAL_BUILD_PROFILE}
      clair_commit=#{clair_commit(root)}
      clair_build_profile=#{context.fetch("CLAIR_BUILD_PROFILE")}
    METADATA
  )
end


desc "Build the Debian binary package"
task :"debian-package" do
  version, revision = release_identity
  expected = debian_package_version(version, revision)
  actual = capture_command(DPKG_PARSECHANGELOG, "-SVersion")
  abort "Debian changelog version #{actual} does not match #{expected}" unless
    actual == expected
  verify_sonbal_package_checkout
  expected_sonbal = sonbal_commit
  package_clair = nil

  with_package_tmpdir("sonbal-debian-package-") do |workspace|
    package_source = File.join(workspace, "source")
    clone_committed_checkout(__dir__, package_source, expected_sonbal)

    with_package_dependency_snapshot do |clair, clair_rev|
      package_clair = clair_rev
      puts "Debian Sonbal snapshot=#{expected_sonbal}"
      puts "Debian Clair snapshot=#{clair_rev}"
      Dir.chdir(package_source) do
        sh({"CLAIR_ROOT" => clair}, DPKG_BUILDPACKAGE, "-b", "-us", "-uc")
      end
    end

    artifact_dir = File.join(__dir__, BUILD_DIR, "package", "debian")
    debs = Dir.glob(File.join(workspace, "*.deb"))
    changes = Dir.glob(File.join(workspace, "*.changes"))
    buildinfo = Dir.glob(File.join(workspace, "*.buildinfo"))
    unless debs.length == 1 && changes.length == 1 && buildinfo.length == 1
      abort "unexpected Debian artifact set in #{workspace}"
    end
    prepare_package_artifact_dir(artifact_dir)
    cp debs + changes + buildinfo, artifact_dir
    artifact = File.join(artifact_dir, File.basename(debs.fetch(0)))
    sh RbConfig.ruby, DEBIAN_PACKAGE_CHECK, artifact, expected,
       expected_sonbal, package_clair
    puts "Debian artifacts=#{artifact_dir}"
  end
end


desc "Inspect the current Debian package artifact without root"
task :"debian-package-check" => :policy do
  version, revision = release_identity
  expected = debian_package_version(version, revision)
  artifacts = Dir.glob(File.join(BUILD_DIR, "package", "debian", "sonbal_*.deb"))
  abort "expected exactly one Sonbal Debian package artifact" unless
    artifacts.length == 1
  root = clair_root
  sh RbConfig.ruby, DEBIAN_PACKAGE_CHECK, artifacts.fetch(0), expected,
     sonbal_commit, clair_commit(root)
end


desc "Build the FreeBSD native package"
task :"freebsd-package" do
  version, revision = release_identity
  expected = freebsd_package_version(version, revision)
  verify_sonbal_package_checkout
  host_context = clair_build_context(clair_root)
  abort "FreeBSD package build requires a FreeBSD target" unless
    host_context.fetch("CLAIR_TARGET_OS") == "freebsd"
  expected_sonbal = sonbal_commit

  with_package_tmpdir("sonbal-freebsd-package-") do |workspace|
    package_source = File.join(workspace, "source")
    clone_committed_checkout(__dir__, package_source, expected_sonbal)
    source_date_epoch = git_commit_epoch(package_source, expected_sonbal)

    with_package_dependency_snapshot do |clair, clair_rev|
      puts "FreeBSD Sonbal snapshot=#{expected_sonbal}"
      puts "FreeBSD Clair snapshot=#{clair_rev}"
      Dir.chdir(package_source) do
        sh({"CLAIR_ROOT" => clair,
            "CLAIR_BUILD_PROFILE" => "release",
            "CLAIR_SECURITY_INSTRUMENTATION" => "none",
            "CLAIR_LIBRARY_TYPE" => "static-pic",
            "SONBAL_BUILD_PROFILE" => "release"}, RAKE, "build")
        sh RbConfig.ruby, FREEBSD_DEPLOYMENT_CHECK,
           FREEBSD_OPENAI_RC, FREEBSD_DEFAULT_CONFIG, FREEBSD_OPENAI_CONFIG,
           FREEBSD_PLATFORM_CONFIG, FREEBSD_PRE_INSTALL
      end

      stage = File.join(workspace, "stage")
      local = File.join(stage, "usr", "local")
      %w[bin lib/sonbal/connectors etc/sonbal etc/rc.d share/sonbal].each do |path|
        mkdir_p File.join(local, path)
      end
      package_context = host_context.merge(
        "CLAIR_ARTIFACT_PROFILE" => "release",
        "CLAIR_LIBRARY_TYPE" => "static-pic"
      )
      package_executable = product_executable(
        package_context,
        build_root: File.join(package_source, BUILD_DIR),
        build_profile: "release"
      )
      cp package_executable, File.join(local, "bin", "sonbal")
      sanitize_packaged_executable(File.join(local, "bin", "sonbal"))
      chmod 0o555, File.join(local, "bin", "sonbal")

      package_connector = product_connector_library(
        "sonbal_connector_openai",
        package_context,
        build_root: File.join(package_source, BUILD_DIR),
        build_profile: "release"
      )
      staged_connector = File.join(
        local, "lib", "sonbal", "connectors",
        "libsonbal_connector_openai.#{RbConfig::CONFIG.fetch('DLEXT')}"
      )
      cp package_connector, staged_connector
      sanitize_packaged_executable(staged_connector)
      chmod 0o555, staged_connector

      cp File.join(package_source, FREEBSD_DEFAULT_CONFIG),
         File.join(local, "etc", "sonbal", "sonbal.yaml.sample")
      chmod 0o644, File.join(local, "etc", "sonbal", "sonbal.yaml.sample")
      cp File.join(package_source, FREEBSD_OPENAI_CONFIG),
         File.join(local, "etc", "sonbal", "openai.json.sample")
      chmod 0o644, File.join(local, "etc", "sonbal", "openai.json.sample")
      cp File.join(package_source, FREEBSD_OPENAI_RC),
         File.join(local, "etc", "rc.d")
      chmod 0o555, File.join(local, "etc", "rc.d", "sonbal_openai")

      curl_package = freebsd_installed_package("curl")
      abort "unexpected FreeBSD curl package origin" unless
        curl_package.fetch("origin") == "ftp/curl"
      File.write(
        File.join(local, "share", "sonbal", "package-revisions"),
        <<~METADATA
          package_version=#{expected}
          sonbal_release=#{version}-#{revision}
          sonbal_commit=#{expected_sonbal}
          sonbal_build_profile=release
          clair_commit=#{clair_rev}
          clair_build_profile=release
          curl_package_name=#{curl_package.fetch("name")}
          curl_package_origin=#{curl_package.fetch("origin")}
          curl_package_version=#{curl_package.fetch("version")}
        METADATA
      )
      chmod 0o644, File.join(local, "share", "sonbal", "package-revisions")

      source_time = Time.at(source_date_epoch).utc
      [
        File.join(local, "bin", "sonbal"),
        staged_connector,
        File.join(local, "etc", "rc.d", "sonbal_openai"),
        File.join(local, "etc", "sonbal", "sonbal.yaml.sample"),
        File.join(local, "etc", "sonbal", "openai.json.sample"),
        File.join(local, "share", "sonbal", "package-revisions")
      ].each do |path|
        File.utime(source_time, source_time, path)
      end

      manifest = {
        "name" => "sonbal", "version" => expected, "origin" => "local/sonbal",
        "comment" => "Bounded noninteractive MCP execution service",
        "desc" => "Sonbal provides bounded noninteractive MCP process execution.",
        "maintainer" => "hodong@nimfsoft.com",
        "www" => "https://github.com/hodong-kim/sonbal",
        "licenses" => [SONBAL_LICENSE_ID],
        "prefix" => "/usr/local", "abi" => freebsd_pkg_config("ABI"),
        "arch" => freebsd_pkg_config("ALTABI"),
        "users" => ["sonbal"],
        "groups" => ["sonbal"],
        "deps" => {
          curl_package.fetch("name") => {
            "origin" => curl_package.fetch("origin"),
            "version" => curl_package.fetch("version")
          }
        },
        "scripts" => {
          "pre-install" => File.read(File.join(package_source, FREEBSD_PRE_INSTALL))
        }
      }
      metadata = File.join(workspace, "metadata")
      mkdir_p metadata
      File.write(File.join(metadata, "+MANIFEST"), JSON.pretty_generate(manifest))
      File.write(
        File.join(metadata, "+DISPLAY"),
        File.read(
          File.join(package_source, PACKAGE_DISCLAIMER), encoding: "UTF-8"
        )
      )
      output = File.join(workspace, "packages")
      mkdir_p output
      sh PKG, "create", "-r", stage, "-m", metadata,
         "-p", File.join(package_source, FREEBSD_PACKAGE_PLIST), "-o", output
      packages = Dir.glob(File.join(output, "sonbal-*.pkg"))
      abort "unexpected FreeBSD package artifact set" unless packages.length == 1
      artifact = packages.fetch(0)
      sh RbConfig.ruby, File.join(package_source, FREEBSD_PACKAGE_CHECK), artifact,
         expected, expected_sonbal, clair_rev,
         source_date_epoch.to_s, PKG, READELF
      artifact_dir = File.join(__dir__, BUILD_DIR, "package", "freebsd")
      prepare_package_artifact_dir(artifact_dir)
      cp artifact, artifact_dir
      puts "FreeBSD artifact=#{File.join(artifact_dir, File.basename(artifact))}"
    end
  end
end


desc "Inspect the current FreeBSD package artifact without root"
task :"freebsd-package-check" => :policy do
  version, revision = release_identity
  expected = freebsd_package_version(version, revision)
  artifact = freebsd_package_artifact!
  revisions = freebsd_artifact_revision_metadata(artifact)
  abort "FreeBSD artifact version #{revisions.fetch('package_version')} does not match #{expected}" unless
    revisions.fetch("package_version") == expected
  root = clair_root
  [[__dir__, revisions.fetch("sonbal_commit")],
   [root, revisions.fetch("clair_commit")]].each do |repo, commit|
    sh GIT, "-C", repo, "cat-file", "-e", "#{commit}^{commit}"
  end
  source_date_epoch = git_commit_epoch(
    __dir__, revisions.fetch("sonbal_commit")
  )
  sh RbConfig.ruby, FREEBSD_PACKAGE_CHECK, artifact, expected,
     revisions.fetch("sonbal_commit"), revisions.fetch("clair_commit"),
     source_date_epoch.to_s, PKG, READELF
end


desc "Build the FreeBSD package twice and require byte reproducibility"
task :"freebsd-package-reproducibility-check" => :"package-workspace-check" do
  context = clair_build_context(clair_root)
  abort "FreeBSD package reproducibility requires a FreeBSD target" unless
    context.fetch("CLAIR_TARGET_OS") == "freebsd"
  verify_sonbal_package_checkout

  with_package_tmpdir("sonbal-freebsd-reproducibility-") do |workspace|
    snapshots = []
    2.times do |index|
      sh RAKE, "freebsd-package"
      artifact = freebsd_package_artifact!
      snapshot = File.join(workspace, "build-#{index + 1}.pkg")
      FileUtils.copy_file(artifact, snapshot)
      snapshots << snapshot
    end

    unless FileUtils.compare_file(snapshots.fetch(0), snapshots.fetch(1))
      first = Digest::SHA256.file(snapshots.fetch(0)).hexdigest
      second = Digest::SHA256.file(snapshots.fetch(1)).hexdigest
      abort(
        "FreeBSD package reproducibility failed: #{first} != #{second}"
      )
    end

    artifact = freebsd_package_artifact!
    sha256 = Digest::SHA256.file(artifact).hexdigest
    puts "FreeBSD reproducibility=PASS"
    puts "FreeBSD artifact=#{artifact}"
    puts "FreeBSD artifact_size=#{File.size(artifact)}"
    puts "FreeBSD artifact_sha256=#{sha256}"
  end
end


desc "Validate a running Linux OpenAI service as the sonbal identity"
task :"linux-openai-service-running-check" => :policy do
  unless File.file?(LINUX_OPENAI_SERVICE_CHECK)
    message =
      "Linux OpenAI service check is missing: " +
      LINUX_OPENAI_SERVICE_CHECK
    abort message
  end
  sh RbConfig.ruby, LINUX_OPENAI_SERVICE_CHECK, "running"
end


desc "Validate a stopped Linux OpenAI service as the sonbal identity"
task :"linux-openai-service-stopped-check" => :policy do
  unless File.file?(LINUX_OPENAI_SERVICE_CHECK)
    message =
      "Linux OpenAI service check is missing: " +
      LINUX_OPENAI_SERVICE_CHECK
    abort message
  end
  sh RbConfig.ruby, LINUX_OPENAI_SERVICE_CHECK, "stopped"
end


desc "Validate a running FreeBSD OpenAI service as the sonbal identity"
task :"freebsd-openai-service-running-check" => :policy do
  unless File.file?(FREEBSD_OPENAI_SERVICE_CHECK)
    message = "FreeBSD OpenAI service check is missing: " \
      "#{FREEBSD_OPENAI_SERVICE_CHECK}"
    abort message
  end
  sh RbConfig.ruby, FREEBSD_OPENAI_SERVICE_CHECK, "running"
end


desc "Validate a stopped FreeBSD OpenAI service as the sonbal identity"
task :"freebsd-openai-service-stopped-check" => :policy do
  unless File.file?(FREEBSD_OPENAI_SERVICE_CHECK)
    message = "FreeBSD OpenAI service check is missing: " \
      "#{FREEBSD_OPENAI_SERVICE_CHECK}"
    abort message
  end
  sh RbConfig.ruby, FREEBSD_OPENAI_SERVICE_CHECK, "stopped"
end


desc "Validate the installed FreeBSD package state as the sonbal identity"
task :"freebsd-installed-check" => :policy do
  abort "FreeBSD installed check is missing: #{FREEBSD_INSTALLED_CHECK}" unless
    File.file?(FREEBSD_INSTALLED_CHECK)
  sh RbConfig.ruby, FREEBSD_INSTALLED_CHECK, freebsd_package_artifact!
end


desc "Validate the installed Debian connector-only package state without root"
task :"debian-installed-check" => :policy do
  abort "Debian installed check is missing: #{DEBIAN_INSTALLED_CHECK}" unless
    File.file?(DEBIAN_INSTALLED_CHECK)
  artifacts = Dir.glob(File.join(BUILD_DIR, "package", "debian", "sonbal_*.deb"))
  abort "expected exactly one Sonbal Debian package artifact" unless
    artifacts.length == 1
  sh RbConfig.ruby, DEBIAN_INSTALLED_CHECK, artifacts.fetch(0)
end


desc "Build and run Sonbal over stdio until EOF"
task run: :build do
  context = current_clair_context
  ensure_native_target!(context)
  sh product_executable(context)
end


desc "Build the Clair.Test-backed native test executable"
task :"test-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)

  puts "Clair root=#{root}"
  puts "Clair commit=#{clair_commit(root)}"
  puts "Clair target=#{context.fetch("CLAIR_TARGET")}"
  puts "Clair target OS=#{context.fetch("CLAIR_TARGET_OS")}"
  puts "Clair profile=#{context.fetch("CLAIR_BUILD_PROFILE")}"

  prepare_clair_production_library(root)
  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     TEST_PROJECT
  verify_artifact(test_executable("sonbal-tests", context))
end


desc "Build and run the native test suite"
task :"native-test" => :"test-build" do
  context = current_clair_context
  ensure_native_target!(context)
  sh test_executable("sonbal-tests", context)
end


desc "Build the PCA-04 OpenAI bounded protocol test"
task :"openai-protocol-test-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_PROTOCOL_TEST_PROJECT

  verify_artifact(
    test_executable("sonbal-connector-openai-protocol-test", context)
  )
end


desc "Run the PCA-04 OpenAI bounded protocol test"
task :"openai-protocol-test" => :"openai-protocol-test-build" do
  context = current_clair_context
  ensure_native_target!(context)
  sh test_executable("sonbal-connector-openai-protocol-test", context)
end


desc "Build the PCA-04 OpenAI connector initialization fixture"
task :"openai-connector-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_CONNECTOR_PROJECT

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_CONNECTOR_FIXTURE_PROJECT

  verify_artifact(
    product_connector_library("sonbal_connector_openai", context)
  )
  verify_artifact(
    test_executable("sonbal-connector-openai-fixture", context)
  )
end


desc "Run the PCA-04 OpenAI initialization-boundary integration"
task :"openai-connector-integration" => :"openai-connector-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_CONNECTOR_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-fixture", context),
     product_connector_library("sonbal_connector_openai", context)
end


desc "Build the PCA-04 OpenAI bounded HTTP primitive test"
task :"openai-http-test-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_HTTP_TEST_PROJECT

  verify_artifact(
    test_executable("sonbal-connector-openai-http-test", context)
  )
end


desc "Run the PCA-04 OpenAI HTTP wire integration"
task :"openai-http-integration" => :"openai-http-test-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_HTTP_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-http-test", context)
end


desc "Build the PCA-04 OpenAI bounded transport test"
task :"openai-transport-test-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_TRANSPORT_TEST_PROJECT

  verify_artifact(
    test_executable("sonbal-connector-openai-transport-test", context)
  )
end


desc "Run the PCA-04 OpenAI queue/deadline integration"
task :"openai-transport-integration" => :"openai-transport-test-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_TRANSPORT_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-transport-test", context)
end


desc "Build the PCA-04 OpenAI runtime transport fixture"
task :"openai-runtime-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_RUNTIME_PLUGIN_PROJECT

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_RUNTIME_FIXTURE_PROJECT

  verify_artifact(
    test_library("sonbal_connector_openai_runtime_plugin", context)
  )
  verify_artifact(
    test_executable("sonbal-connector-openai-runtime-fixture", context)
  )
end


desc "Run the PCA-04 OpenAI runtime wire lifecycle"
task :"openai-runtime-integration" => :"openai-runtime-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_RUNTIME_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-runtime-fixture", context),
     test_library("sonbal_connector_openai_runtime_plugin", context)
end


desc "Build the bounded connector product-service fixture"
task :"connector-service-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_RUNTIME_PLUGIN_PROJECT

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     CONNECTOR_SERVICE_FIXTURE_PROJECT

  verify_artifact(
    test_library("sonbal_connector_openai_runtime_plugin", context)
  )
  verify_artifact(
    test_executable("sonbal-connector-service-fixture", context)
  )
end


desc "Run connector product-service startup and bounded shutdown integration"
task :"connector-service-integration" => :"connector-service-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     CONNECTOR_SERVICE_INTEGRATION_TEST,
     test_executable("sonbal-connector-service-fixture", context),
     test_library("sonbal_connector_openai_runtime_plugin", context)
end


desc "Build the PCA-05A Linux isolated OpenAI E2E fixture"
task :"openai-e2e-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  ensure_native_target!(context)
  abort "PCA-05A isolated E2E is Linux-only" unless
    RbConfig::CONFIG.fetch("host_os").include?("linux")
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_RUNTIME_PLUGIN_PROJECT

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     OPENAI_E2E_FIXTURE_PROJECT

  verify_artifact(
    test_library("sonbal_connector_openai_runtime_plugin", context)
  )
  verify_artifact(
    test_executable("sonbal-connector-openai-e2e-fixture", context)
  )
end


desc "Run PCA-05A isolated seven-tool OpenAI service acceptance"
task :"openai-e2e-integration" => :"openai-e2e-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_E2E_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-e2e-fixture", context),
     test_library("sonbal_connector_openai_runtime_plugin", context)
end


desc "Run PCA-05B permanent failure acceptance"
task :"openai-e2e-failure-integration" => :"openai-e2e-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_FAILURE_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-e2e-fixture", context),
     test_library("sonbal_connector_openai_runtime_plugin", context)
end


desc "Run PCA-05B repeated Linux product-service stability"
task :"openai-e2e-stability" => :"openai-e2e-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     OPENAI_STABILITY_INTEGRATION_TEST,
     test_executable("sonbal-connector-openai-e2e-fixture", context),
     test_library("sonbal_connector_openai_runtime_plugin", context)
end


desc "Build the connector host and dynamic-plugin fixtures"
task :"connector-host-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  [
    CONNECTOR_FAKE_PLUGIN_PROJECT,
    CONNECTOR_BAD_ABI_PROJECT,
    CONNECTOR_MISSING_SYMBOL_PROJECT
  ].each do |project|
    sh GPRBUILD,
       *clair_project_arguments(root, context),
       *sonbal_project_arguments,
       "-P",
       project
  end

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     CONNECTOR_HOST_FIXTURE_PROJECT

  verify_artifact(test_executable("sonbal-connector-host-fixture", context))
  verify_artifact(test_library("sonbal_connector_fake_plugin", context))
  verify_artifact(test_library("sonbal_connector_bad_abi", context))
  verify_artifact(test_library("sonbal_connector_missing_symbol", context))
end


desc "Run connector host dynamic lifecycle integration"
task :"connector-host-integration" => :"connector-host-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)
  sh RbConfig.ruby,
     CONNECTOR_HOST_INTEGRATION_TEST,
     test_executable("sonbal-connector-host-fixture", context),
     test_library("sonbal_connector_fake_plugin", context),
     test_library("sonbal_connector_bad_abi", context),
     test_library("sonbal_connector_missing_symbol", context)
end


desc "Build the connector request-flow fixture"
task :"connector-server-fixture-build" => :"connector-host-fixture-build" do
  root = clair_root
  context = clair_build_context(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     CONNECTOR_SERVER_FIXTURE_PROJECT

  verify_artifact(test_executable("sonbal-connector-server-fixture", context))
end


desc "Run connector request-flow integration"
task :"connector-server-integration" => :"connector-server-fixture-build" do
  context = current_clair_context
  ensure_native_target!(context)
  sh RbConfig.ruby,
     CONNECTOR_SERVER_INTEGRATION_TEST,
     test_executable("sonbal-connector-server-fixture", context),
     test_library("sonbal_connector_fake_plugin", context)
end


desc "Build the test-only configurable stdio server fixture"
task :"stdio-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     STDIO_FIXTURE_PROJECT
  verify_artifact(test_executable("sonbal-stdio-server-fixture", context))
end


desc "Build the Clair Event Loop timer-churn diagnostic fixture"
task :"clair-timer-churn-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     CLAIR_TIMER_CHURN_FIXTURE_PROJECT
  verify_artifact(
    test_executable("sonbal-clair-timer-churn-fixture", context)
  )
end


desc "Run the Clair Event Loop timer-churn resource diagnostic"
task :"clair-timer-churn-diagnostic" => :"clair-timer-churn-fixture-build" do
  abort "Clair timer-churn diagnostic is missing" unless
    File.file?(CLAIR_TIMER_CHURN_DIAGNOSTIC)

  sh RbConfig.ruby,
     CLAIR_TIMER_CHURN_DIAGNOSTIC,
     native_test_executable("sonbal-clair-timer-churn-fixture")
end


desc "Build the Clair Event Loop watch-churn diagnostic fixture"
task :"clair-watch-churn-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     CLAIR_WATCH_CHURN_FIXTURE_PROJECT
  verify_artifact(
    test_executable("sonbal-clair-watch-churn-fixture", context)
  )
end


desc "Run the Clair Event Loop watch-churn resource diagnostic"
task :"clair-watch-churn-diagnostic" => :"clair-watch-churn-fixture-build" do
  abort "Clair watch-churn diagnostic is missing" unless
    File.file?(CLAIR_WATCH_CHURN_DIAGNOSTIC)

  sh RbConfig.ruby,
     CLAIR_WATCH_CHURN_DIAGNOSTIC,
     native_test_executable("sonbal-clair-watch-churn-fixture")
end

desc "Build the Ada protected-context churn diagnostic fixture"
task :"ada-protected-context-churn-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  prepare_clair_production_library(root)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     *sonbal_project_arguments,
     "-P",
     ADA_PROTECTED_CONTEXT_CHURN_FIXTURE_PROJECT
  verify_artifact(
    test_executable("sonbal-ada-protected-context-churn-fixture", context)
  )
end


desc "Run plain/protected Ada callback-context churn diagnostics"
task :"ada-protected-context-diagnostic" =>
  :"ada-protected-context-churn-fixture-build" do
  abort "Ada protected-context diagnostic is missing" unless
    File.file?(ADA_PROTECTED_CONTEXT_CHURN_DIAGNOSTIC)

  sh RbConfig.ruby,
     ADA_PROTECTED_CONTEXT_CHURN_DIAGNOSTIC,
     native_test_executable(
       "sonbal-ada-protected-context-churn-fixture"
     )
end


desc "Build the Clair hostile-descendant process fixture"
task :"clair-process-fixture-build" => :policy do
  root = clair_root
  verify_clair_checkout(root)
  context = clair_build_context(root)
  project = File.join(root, CLAIR_PROCESS_FIXTURE_PROJECT)
  executable = clair_process_fixture_executable(context)

  sh GPRBUILD,
     *clair_project_arguments(root, context),
     "-P",
     project
  verify_artifact(executable)
end


desc "Run the local stdio integration suite"
task integration: [
  :build,
  :"stdio-fixture-build",
  :"clair-process-fixture-build"
] do
  abort "integration test is missing: #{INTEGRATION_TEST}" unless
    File.file?(INTEGRATION_TEST)

  context = current_clair_context
  ensure_native_target!(context)

  sh RbConfig.ruby,
     INTEGRATION_TEST,
     product_executable(context),
     test_executable("sonbal-stdio-server-fixture", context),
     clair_process_fixture_executable(context)
  abort "stdio shutdown-signal integration test is missing" unless
    File.file?(STDIO_SIGNAL_INTEGRATION_TEST)
  sh RbConfig.ruby,
     STDIO_SIGNAL_INTEGRATION_TEST,
     product_executable(context),
     test_executable("sonbal-stdio-server-fixture", context),
     clair_process_fixture_executable(context)
end


def systemd_analyze_executable!
  candidates = [ENV["SONBAL_SYSTEMD_ANALYZE"], "/usr/bin/systemd-analyze"].compact
  executable = candidates.find { |path| File.file?(path) && File.executable?(path) }
  abort "systemd-analyze executable not found; set SONBAL_SYSTEMD_ANALYZE" unless executable
  executable
end

desc "Validate Linux connector-only deployment templates"
task :"linux-deployment-check" do
  abort "Linux deployment check is missing: #{LINUX_DEPLOYMENT_CHECK}" unless
    File.file?(LINUX_DEPLOYMENT_CHECK)

  sh RbConfig.ruby,
     LINUX_DEPLOYMENT_CHECK,
     systemd_analyze_executable!,
     LINUX_OPENAI_SERVICE_UNIT,
     LINUX_TMPFILES_CONFIG,
     LINUX_SYSUSERS_CONFIG,
     LINUX_DEFAULT_CONFIG,
     LINUX_OPENAI_CONFIG,
     LINUX_PLATFORM_CONFIG,
     DEBIAN_PREINST,
     DEBIAN_POSTINST,
     DEBIAN_PRERM,
     DEBIAN_POSTRM,
     DEBIAN_INSTALLED_CHECK,
     DEBIAN_RULES,
     DEBIAN_CONTROL,
     PACKAGE_DISCLAIMER
end


desc "Validate FreeBSD connector-only deployment templates"
task :"freebsd-deployment-check" do
  abort "FreeBSD deployment check is missing: #{FREEBSD_DEPLOYMENT_CHECK}" unless
    File.file?(FREEBSD_DEPLOYMENT_CHECK)

  sh RbConfig.ruby,
     FREEBSD_DEPLOYMENT_CHECK,
     FREEBSD_OPENAI_RC,
     FREEBSD_DEFAULT_CONFIG,
     FREEBSD_OPENAI_CONFIG,
     FREEBSD_PLATFORM_CONFIG,
     FREEBSD_PRE_INSTALL
end


desc "Self-test the test-only ChatGPT long-running job MCP probe"
task :"chatgpt-job-probe-self-test" => :policy do
  abort "ChatGPT job probe is missing" unless File.file?(CHATGPT_JOB_PROBE)
  sh RbConfig.ruby, CHATGPT_JOB_PROBE, "self-test"
end


desc "Validate the shared package workspace boundary"
task :"package-workspace-check" => :policy do
  prepare_package_workspace_root
  puts "[PASS] package workspace shared-group preflight"
end


desc "Validate standalone fixture build orchestration"
task :"rake-orchestration-check" => :policy do
  abort "Rake orchestration check is missing" unless
    File.file?(RAKE_ORCHESTRATION_CHECK)
  sh RbConfig.ruby, RAKE_ORCHESTRATION_CHECK, __FILE__
end


def native_deployment_check_task
  host_os = RbConfig::CONFIG.fetch("host_os")
  return :"freebsd-deployment-check" if host_os.include?("freebsd")
  return :"linux-deployment-check" if host_os.include?("linux")

  nil
end


all_test_tasks = [
  :"chatgpt-job-probe-self-test",
  :"rake-orchestration-check",
  :"connector-host-integration",
  :"connector-server-integration",
  :"openai-protocol-test",
  :"openai-connector-integration",
  :"openai-http-integration",
  :"openai-transport-integration",
  :"openai-runtime-integration",
  :"connector-service-integration"
]
if RbConfig::CONFIG.fetch("host_os").include?("linux")
  all_test_tasks << :"openai-e2e-integration"
  all_test_tasks << :"openai-e2e-failure-integration"
end
all_test_tasks.concat(
  [
    :"native-test",
    :integration
  ]
)
if (deployment_check = native_deployment_check_task)
  all_test_tasks.unshift(:"package-workspace-check")
  all_test_tasks << deployment_check
end

desc "Run all tests"
task test: all_test_tasks


desc "Remove generated Sonbal build artifacts"
task :clean do
  rm_rf BUILD_DIR
end


task default: :build
