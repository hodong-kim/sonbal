#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_rake_orchestration_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

rakefile = ARGV.fetch(0) { abort "Rakefile path is required" }
source = File.read(rakefile, encoding: "UTF-8")
root = File.dirname(File.expand_path(rakefile))

def require_token(source, token, label)
  abort "#{label} lost #{token.inspect}" unless source.include?(token)
end

def reject_token(source, token, label)
  abort "#{label} retained #{token.inspect}" if source.include?(token)
end

require_token(
  source,
  'CLAIR_DEPENDENCY_BUILD_ROOT = File.join(PACKAGE_BUILD_ROOT, "deps", "clair")',
  "Clair consumer root"
)
%w[
  FASYN_DEPENDENCY_BUILD_ROOT
  FASYN_ROOT
  fasyn_root
  fasyn_commit
  fasyn_project_arguments
  fastcgi
  nginx_executable
  tunnel_client_executable
  ACCEPTED_TUNNEL_CLIENT_VERSION
].each do |token|
  reject_token(source, token, "retired ingress orchestration")
end

snapshot = source[
  /def with_package_dependency_snapshot\n.*?^end$/m
]
abort "single-dependency package snapshot helper is missing" if snapshot.nil?
require_token(snapshot, "source_clair = clair_root", "package snapshot")
require_token(snapshot, "yield clair, expected_clair", "package snapshot")
reject_token(snapshot, "fasyn", "package snapshot")

product_build = source[/task build: :policy do.*?^end$/m]
abort "product build task is missing" if product_build.nil?
[
  "prepare_clair_production_library(root)",
  "*clair_project_arguments(root, context)",
  "*sonbal_project_arguments",
  'gprbuild_switches << "-R" if SONBAL_BUILD_PROFILE == "release"',
  "OPENAI_CONNECTOR_PROJECT"
].each { |token| require_token(product_build, token, "product build") }

test_build = source[/task :"test-build" => :policy do.*?^end$/m]
abort "test-build task is missing" if test_build.nil?
require_token(test_build, "prepare_clair_production_library(root)", "test build")
reject_token(test_build, "ensure_native_target!", "test build")
reject_token(test_build, "fasyn", "test build")

%w[
  openai-runtime-fixture-build
  connector-service-fixture-build
  openai-e2e-fixture-build
].each do |name|
  body = source[/task :"#{Regexp.escape(name)}" => :policy do.*?^end$/m]
  abort "surviving connector fixture task is missing: #{name}" if body.nil?
  reject_token(body, "fasyn", name)
  require_token(body, "prepare_clair_production_library(root)", name)
end

debian_package = source[
  /desc "Build the Debian binary package".*?(?=\ndesc "Inspect the current Debian package artifact)/m
]
abort "Debian package task is missing" if debian_package.nil?
require_token(
  debian_package,
  "with_package_dependency_snapshot do |clair, clair_rev|",
  "Debian package"
)
require_token(debian_package, '{"CLAIR_ROOT" => clair}', "Debian package")
reject_token(debian_package, "FASYN", "Debian package")
reject_token(debian_package, "fasyn", "Debian package")

freebsd_package = source[
  /desc "Build the FreeBSD native package".*?(?=\ndesc "Inspect the current FreeBSD package artifact)/m
]
abort "FreeBSD package task is missing" if freebsd_package.nil?
require_token(
  freebsd_package,
  "with_package_dependency_snapshot do |clair, clair_rev|",
  "FreeBSD package"
)
require_token(freebsd_package, '"users" => ["sonbal"]', "FreeBSD package")
require_token(freebsd_package, 'FREEBSD_OPENAI_RC', "FreeBSD package")
%w[fasyn fastcgi nginx tunnel].each do |token|
  reject_token(freebsd_package, token, "FreeBSD package")
end

linux_deployment = source[
  /desc "Validate Linux connector-only deployment templates".*?^end$/m
]
abort "Linux connector-only deployment task is missing" if linux_deployment.nil?
[
  "LINUX_OPENAI_SERVICE_UNIT",
  "LINUX_TMPFILES_CONFIG",
  "LINUX_SYSUSERS_CONFIG",
  "DEBIAN_PREINST",
  "DEBIAN_POSTINST",
  "DEBIAN_PRERM",
  "DEBIAN_POSTRM"
].each { |token| require_token(linux_deployment, token, "Linux deployment") }
%w[FASTCGI TUNNEL NGINX].each do |token|
  reject_token(linux_deployment, token, "Linux deployment")
end

freebsd_deployment = source[
  /desc "Validate FreeBSD connector-only deployment templates".*?^end$/m
]
abort "FreeBSD connector-only deployment task is missing" if freebsd_deployment.nil?
require_token(freebsd_deployment, "FREEBSD_OPENAI_RC", "FreeBSD deployment")
%w[FASTCGI TUNNEL NGINX].each do |token|
  reject_token(freebsd_deployment, token, "FreeBSD deployment")
end

package_workspace = source[
  /desc "Validate the shared package workspace boundary".*?^end$/m
]
abort "package workspace gate is missing" if package_workspace.nil?
require_token(
  package_workspace,
  "prepare_package_workspace_root",
  "package workspace gate"
)

unless source.include?('all_test_tasks << :"openai-e2e-integration"') &&
       source.include?('all_test_tasks << :"openai-e2e-failure-integration"') &&
       source.include?('all_test_tasks << deployment_check') &&
       source.include?("task test: all_test_tasks")
  abort "canonical test lost connector/deployment acceptance"
end
%w[
  fastcgi-adapter-integration
  fastcgi-server-integration
  security-host-selection-self-test
].each do |task|
  reject_token(source, task, "canonical retired task")
end

linux_service_check = File.read(
  File.join(root, "tests", "sonbal_linux_openai_service_check.rb"),
  encoding: "UTF-8"
)
[
  'state_dir = "/var/lib/sonbal-openai"',
  'unit = "sonbal-openai.service"',
  'unit_props["UnitFileState"] == "disabled"',
  'descendant_of?(row, main_pid, rows_by_pid)',
  'foreign_candidates.empty?',
  'service_roots.length == 1',
  'unit_props["Delegate"] == "yes"',
  'verify_strict_ownership_delegation!(main_pid, sonbal.uid, sonbal.gid)',
  'puts "[PASS] Linux OpenAI service stopped and settled"'
].each { |token| require_token(linux_service_check, token, "Linux live checker") }

freebsd_service_check = File.read(
  File.join(root, "tests", "sonbal_freebsd_openai_service_check.rb"),
  encoding: "UTF-8"
)
[
  'state_dir = "/var/db/sonbal-openai"',
  'expected_args = "#{sonbal_binary} --connector openai"',
  'descendant_of?(row, child_pid, rows_by_pid)',
  'foreign_candidates.empty?',
  'service_roots.length == 1',
  'supervisor[2] == "root" && supervisor[3] == "wheel"',
  'assert_root_pidfile(supervisor_pidfile, wheel.gid)',
  'assert_root_pidfile(child_pidfile, wheel.gid)',
  'puts "[PASS] FreeBSD OpenAI service stopped and settled"'
].each { |token| require_token(freebsd_service_check, token, "FreeBSD live checker") }

sonbal_config = File.read(File.join(root, "sonbal_config.gpr"), encoding: "UTF-8")
%w[
  Product_Artifact_Profile_Name
  Test_Artifact_Profile_Name
  Product_Object_Dir
  Product_Exec_Dir
  Tests_Object_Root
  Tests_Exec_Dir
].each { |token| require_token(sonbal_config, token, "Sonbal build config") }

unsupported_true_paths = Dir.glob(
  File.join(root, "tests", "**", "*.{rb,adb,ads}")
).reject { |path| File.expand_path(path) == File.expand_path(__FILE__) }
unsupported_true_paths.select! do |path|
  File.read(path, encoding: "UTF-8").include?('"/bin/true"')
end
unless unsupported_true_paths.empty?
  names = unsupported_true_paths.map { |path| path.delete_prefix(root + "/") }
  abort "tests must use common /usr/bin/true: #{names.join(', ')}"
end

puts "[PASS] standalone fixture build orchestration"
