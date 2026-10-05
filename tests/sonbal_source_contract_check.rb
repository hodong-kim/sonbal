#!/usr/bin/env ruby
# frozen_string_literal: true
# =============================================================================
# sonbal_source_contract_check.rb
# Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
# SPDX-License-Identifier: 0BSD
# =============================================================================

root = File.expand_path("..", __dir__)

def read_utf8(root, relative)
  File.read(File.join(root, relative), encoding: "UTF-8")
end

def descriptor_name(texts, constant)
  texts.each do |text|
    block = text[/#{Regexp.escape(constant)}\s*: constant String :=(.*?);/m, 1]
    next if block.nil?

    name = block[/""name"":""([a-z_]+)""/, 1]
    abort "tool descriptor has no name: #{constant}" if name.nil?
    return name
  end
  abort "tool descriptor is missing: #{constant}"
end

def positive_constant(text, name)
  raw = text[
    /#{Regexp.escape(name)}\s*: constant Positive :=\s*([0-9_]+)\s*;/m,
    1
  ]
  abort "positive constant is missing: #{name}" if raw.nil?
  raw.delete("_").to_i
end

def documented_number(text, pattern, label)
  raw = text[pattern, 1]
  abort "documented bound is missing: #{label}" if raw.nil?
  raw.delete(",_").to_i
end

def check_equal(actual, expected, label)
  return if actual == expected

  abort "#{label} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
end

dispatcher_spec = read_utf8(root, "src/sonbal-mcp-dispatcher.ads")
dispatcher_body = read_utf8(root, "src/sonbal-mcp-dispatcher.adb")
json_spec = read_utf8(root, "src/sonbal-mcp-json.ads")
json_body = read_utf8(root, "src/sonbal-mcp-json.adb")
agents = read_utf8(root, "AGENTS.md")
design_router = read_utf8(root, "docs/architecture/design.md")
design_connectors = read_utf8(root, "docs/architecture/design/connectors.md")
design_mcp = read_utf8(root, "docs/architecture/design/mcp-and-execution.md")
connector_abi_spec = read_utf8(root, "src/sonbal-connector_abi.ads")
connector_abi_header = read_utf8(root, "include/sonbal_connector_abi.h")
connector_host = read_utf8(root, "src/sonbal-connector_host.adb")
openai_connector = read_utf8(root, "connectors/openai/sonbal_connector_openai.c")
openai_transport = read_utf8(root, "connectors/openai/sonbal_openai_transport.c")
openai_transport_header = read_utf8(root, "connectors/openai/sonbal_openai_transport.h")
readme = read_utf8(root, "README.md")
package_disclaimer = read_utf8(root, "deployment/package-disclaimer.txt")
readme_flat = readme.gsub(/\s+/, " ")
package_disclaimer_flat = package_disclaimer.gsub(/\s+/, " ")

abort "AGENTS must route detailed documentation through docs/README.md" unless
  agents.include?("docs/README.md")
abort "AGENTS must not require preloading every detailed document" if
  agents.match?(/read.*all documents under `docs\/`/i)

abort "README commercialization notice is missing" unless
  readme.include?("## Commercialization") &&
    readme_flat.include?("free and open source under 0BSD") &&
    readme_flat.include?("Commercial or paid editions") &&
    readme_flat.include?("introduced in the future")

abort "README external contribution policy is missing" unless
  readme.include?("## Contributions") &&
    readme_flat.include?("External code contributions are not accepted.") &&
    readme_flat.include?(
      "Development is limited to the maintainer and people explicitly " +
      "authorized to work on the project."
    )

abort "README disclaimer section is missing" unless
  readme.include?("## Disclaimer")
[
  "AI systems can make mistakes or behave unexpectedly",
  "isolated or restricted environment",
  "Do not expose passwords, private keys, access tokens",
  "maximum extent permitted by applicable law",
  "Use Sonbal at your own risk"
].each do |text|
  abort "README disclaimer lost #{text.inspect}" unless
    readme_flat.include?(text)
end
[
  "AI systems can make mistakes or behave unexpectedly",
  "isolated or restricted environment",
  "Do not expose passwords, private keys, access tokens",
  "maximum extent permitted by applicable law",
  "Installation does not start Sonbal",
  "Use Sonbal at your own risk"
].each do |text|
  abort "package disclaimer lost #{text.inspect}" unless
    package_disclaimer_flat.include?(text)
end
if package_disclaimer.lines.any? { |line| line.chomp.length > 72 }
  abort "package disclaimer exceeds 72 columns"
end

%w[
  docs/design.md
  docs/development.md
  docs/installation.md
  docs/deployment-security.md
  docs/engineering-principles.md
  docs/style-guide.md
].each do |retired|
  abort "retired top-level documentation path returned: #{retired}" if
    File.exist?(File.join(root, retired))
end

docs_index = read_utf8(root, "docs/README.md")
%w[
  architecture/design.md
  architecture/engineering-principles.md
  architecture/dependency-builds.md
  architecture/implementation-boundary.md
  architecture/deployment-security.md
  architecture/review-map.md
  architecture/client-support.md
  architecture/style-guide.md
  workflows/development-cycle.md
  workflows/build-and-validation.md
  workflows/installation.md
  workflows/clair-co-development.md
  roadmaps/README.md
].each do |relative|
  abort "documentation router is missing #{relative}" unless
    docs_index.include?(relative)
end

%w[
  design/overview-and-trust.md
  design/connectors.md
  design/mcp-and-execution.md
  design/runtime-and-failure.md
].each do |relative|
  abort "design router is missing " + relative unless
    design_router.include?(relative)
end

connector_contract_sources = {
  "connector ABI Ada spec" => connector_abi_spec,
  "connector ABI C header" => connector_abi_header,
  "connector host" => connector_host,
  "OpenAI connector" => openai_connector,
  "OpenAI transport" => openai_transport,
  "OpenAI transport header" => openai_transport_header,
  "stable connector design" => design_connectors
}
connector_contract_sources.each do |label, source|
  abort "retired connector bound maximum_inflight remains in #{label}" if
    source.include?("maximum_inflight")
  abort "connector active-request bound is missing from #{label}" unless
    source.include?("maximum_active_requests")
end

order_block = dispatcher_body[
  /TOOLS_LIST_RESULT_SUFFIX\s*: constant String :=(.*?);/m,
  1
]
abort "tools/list source assembly is missing" if order_block.nil?
descriptor_constants = order_block.scan(/\b[A-Z_]+_TOOL_DESCRIPTOR\b/)
abort "tools/list source assembly is empty" if descriptor_constants.empty?
source_tools = descriptor_constants.map do |constant|
  descriptor_name([dispatcher_body, dispatcher_spec], constant)
end
abort "tools/list source assembly contains duplicate tool names" unless
  source_tools.uniq.length == source_tools.length

design_block = design_mcp[
  /The current source `tools\/list` surface is exactly, in this order:\s*\n(.*?)(?:\n\n|\z)/m,
  1
]
abort "design current-source tool list is missing" if design_block.nil?
design_tools = design_block.scan(/^\d+\. `([a-z_]+)`$/).flatten

check_equal(design_tools, source_tools, "design current-source tool order")

legacy_wire_members = %w[
  workspaceCapability workspaceState activeWorkCount takeoverId jobId
  nextCursor timeoutMs exitCode launchStage infrastructureStage ownershipStage
]
wire_sources = {
  "dispatcher spec" => dispatcher_spec,
  "dispatcher body" => dispatcher_body,
  "JSON spec" => json_spec,
  "JSON body" => json_body
}
legacy_wire_members.each do |member|
  wire_sources.each do |label, source|
    abort "legacy Sonbal-owned wire member #{member} remains in #{label}" if
      source.include?(member)
  end
end
%w[open_workspace_session close_workspace_session workspace_session stale_session].each do |term|
  wire_sources.each do |label, source|
    abort "retired workspace wire term #{term} remains in #{label}" if
      source.include?(term)
  end
end

tools_list_bound = positive_constant(
  dispatcher_spec, "MAXIMUM_TOOLS_LIST_RESPONSE_BYTES"
)
run_process_bound = positive_constant(
  dispatcher_spec, "MAXIMUM_RUN_PROCESS_RESPONSE_BYTES"
)
run_process_timeout = positive_constant(
  dispatcher_spec, "MAXIMUM_RUN_PROCESS_TIMEOUT_MS"
)

design_tools_list_bound = documented_number(
  design_mcp,
  /complete .*?`tools\/list` response.*?exactly \*\*([0-9,]+) bytes\*\*/m,
  "design tools/list maximum"
)
design_run_process_bound = documented_number(
  design_mcp,
  /maximum serialized\s+`run_process` response remains exactly \*\*([0-9,]+) bytes\*\*/m,
  "design run_process maximum"
)
design_run_process_timeout = documented_number(
  design_mcp,
  /`run_process\.timeout_ms` is `1 \.\. ([0-9_]+)`/,
  "design run_process timeout"
)
check_equal(design_tools_list_bound, tools_list_bound, "design tools/list maximum")
check_equal(design_run_process_bound, run_process_bound, "design run_process maximum")
check_equal(design_run_process_timeout, run_process_timeout, "design run_process timeout")

retired_paths = %w[
  src/sonbal-mcp-fastcgi_adapter.ads
  src/sonbal-mcp-fastcgi_adapter.adb
  src/sonbal-mcp-fastcgi_server.ads
  src/sonbal-mcp-fastcgi_server.adb
  deployment/linux/systemd/sonbal-fastcgi.socket
  deployment/linux/systemd/sonbal-fastcgi.service
  deployment/linux/systemd/sonbal-tunnel.service
  deployment/linux/nginx/sonbal.conf
  deployment/freebsd/rc.d/sonbal_fastcgi
  deployment/freebsd/rc.d/sonbal_tunnel
  deployment/freebsd/inetd/sonbal-fastcgi.conf
  deployment/freebsd/nginx/sonbal.conf
]
retired_paths.each do |relative|
  abort "retired ingress path returned: #{relative}" if
    File.exist?(File.join(root, relative))
end

core_sources = {
  "product GPR" => read_utf8(root, "sonbal.gpr"),
  "native test GPR" => read_utf8(root, "tests/sonbal_tests.gpr"),
  "Rake orchestration" => read_utf8(root, "Rakefile"),
  "product main" => read_utf8(root, "src/sonbal_main.adb")
}
core_sources.each do |label, source|
  %w[fasyn --fastcgi sonbal-fastcgi sonbal-tunnel tunnel-client].each do |term|
    abort "retired ingress term #{term.inspect} remains in #{label}" if
      source.downcase.include?(term.downcase)
  end
end

debian_install = read_utf8(root, "debian/sonbal.install")
freebsd_plist = read_utf8(root, "freebsd/pkg-plist")
%w[fastcgi tunnel nginx].each do |term|
  abort "retired Debian payload #{term} remains" if
    debian_install.downcase.include?(term)
  abort "retired FreeBSD payload #{term} remains" if
    freebsd_plist.downcase.include?(term)
end

puts "[PASS] source/document MCP contract consistency"
