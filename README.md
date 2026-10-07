# Sonbal - Hands and feet for your AI

Sonbal is a security-sensitive local MCP execution substrate for an AI client
on a user-controlled machine. It provides bounded noninteractive process
execution with explicit freshness fencing, finite cancellation, deterministic
cleanup, and a deliberately small MCP surface.

## Current status

The current source exposes a deliberately small seven-tool MCP surface for
health checking, workspace freshness, bounded process execution/jobs, and
bounded file inspection. Exact tool names, ordering, schemas, limits, and result
contracts are owned by
[`docs/architecture/design/mcp-and-execution.md`](docs/architecture/design/mcp-and-execution.md).

Workspace coordination is a generation-fenced freshness mechanism, not a
persistent ownership or application-session model. A successful
`rotate_workspace_token` publishes a fresh opaque `workspace_token` and makes
older tokens for the same workspace root stale for new work admission.
Already admitted work is not cancelled merely because a newer token exists.

`run_process` is synchronous and request-owned. `start_process` creates a
bounded server-owned job that can be polled or cancelled across later requests.
`read_file` performs one bounded, read-only, workspace-relative byte-range
inspection through a strict-owned same-image helper process. All process-creating
forms share one execution-capacity ceiling. Process execution uses a
product-owned minimal environment, retains output within fixed bounds, and
requires strict process-tree ownership before untrusted payload code runs.

Interactive terminal/PTY execution is outside the product contract. Sonbal
never silently falls back to a shell, PTY, or transport-derived execution
context.

Sonbal does not guarantee backward compatibility for its MCP tool API across
releases. First-party consumers migrate directly to the current contract rather
than relying on compatibility aliases for retired wire forms.

## Current architecture

The native AI-facing path is the in-process connector architecture:

```text
AI service/runtime
      |
      v
+---------------------------+
|          sonbal           |
|       one process         |
|                           |
|  dynamic connector plugin |
|            |              |
|        Sonbal Core        |
|            |              |
|       Process Runtime     |
+---------------------------+
```

One Sonbal instance is one `sonbal` process. Connector plugins execute inside
that process and call the local core directly. There is no mandatory
connector-to-core IPC hop and no external nginx/FastCGI/Fasyn/tunnel-client
production ingress in current source or native package payloads.

The OpenAI connector is selected explicitly with
`sonbal --connector openai`. Its persistent credential remains root-only and
is passed into the unprivileged `sonbal` service as already-open descriptor 3.
Linux uses systemd `OpenFile=`; FreeBSD uses the native rc.d launcher plus
`daemon -u sonbal`. Connector-specific networking and provider protocol state
remain outside generic Sonbal core authority.

Sonbal-to-Sonbal transport, remote-worker protocols, source-tree
synchronization, and remote host orchestration are not product requirements.
Users may compose ordinary host tools and workflows around Sonbal's local
process execution as needed.

A Sonbal-created process intentionally carries the host authority available to
the `sonbal` execution identity. Sonbal is not a sandbox and does not claim
per-command filesystem, network, Git, or credential restrictions that it does
not implement.

## Documentation

Use [`docs/README.md`](docs/README.md) as the authoritative documentation
router. It identifies which architecture, workflow, or roadmap document owns a
given task. Repository-wide contributor rules are in [`AGENTS.md`](AGENTS.md).

## Installation and quick start

Prebuilt native packages are available for FreeBSD amd64 and Debian amd64.
Package installation creates the non-login `sonbal` service user and its
primary `sonbal` group. Installation is activation-neutral: installing the
package does not enable or start the OpenAI service. Removing the package does
not automatically remove the `sonbal` service user or `sonbal` group.

### Direct stdio MCP

Run `sonbal` with no connector argument to use the bounded stdio MCP transport:

```sh
sonbal
```

This mode does not require the OpenAI connector service, provider configuration,
or persistent credential.

### Debian

Install a downloaded Debian package:

```sh
sudo apt install ./sonbal_VERSION_amd64.deb
```

Before activating the OpenAI connector, set `tunnel_id` in
`/etc/sonbal/openai.json` and provision the persistent credential at
`/var/lib/sonbal-openai/credential`. The credential directory must be
`root:root` mode `0700`, and the credential must be `root:root` mode `0600`.

Then explicitly enable and start the service:

```sh
sudo systemctl enable --now sonbal-openai.service
systemctl status sonbal-openai.service
```

### FreeBSD

Install a downloaded FreeBSD package:

```sh
sudo pkg install ./sonbal-VERSION.pkg
```

Before activating the OpenAI connector, set `tunnel_id` in
`/usr/local/etc/sonbal/openai.json` and provision the persistent credential at
`/var/db/sonbal-openai/credential`. The credential directory must be
`root:wheel` mode `0700`, and the credential must be `root:wheel` mode `0600`.

Then explicitly enable and start the service:

```sh
sudo sysrc sonbal_openai_enable=YES
sudo service sonbal_openai start
sudo service sonbal_openai status
```

See [`docs/workflows/installation.md`](docs/workflows/installation.md) for the
full installation, credential-provisioning, activation, and validation
procedure.

## Build and test

```sh
rake build
rake test
```

Sonbal consumes a clean Clair source checkout. Clair is available at
https://github.com/hodong-kim/clair. Consumer-owned Clair artifacts are placed
under Sonbal's `build/deps/clair`. Product and test outputs remain inside
Sonbal's own build tree.

Additional validation targets are documented in
[`docs/workflows/build-and-validation.md`](docs/workflows/build-and-validation.md).

## Commercialization

This repository is free and open source under 0BSD. Commercial or paid
editions, services, or related offerings may also be introduced in the future.

## Contributions

External code contributions are not accepted. Development is limited to the
maintainer and people explicitly authorized to work on the project.

## Disclaimer

Sonbal allows AI systems to act on the host machine. AI systems can make
mistakes or behave unexpectedly. Use Sonbal only where failures can be
safely contained. An isolated or restricted environment is strongly
recommended.

Do not expose passwords, private keys, access tokens, personal data,
confidential files, or other sensitive information through Sonbal.

You are responsible for Sonbal's permissions and access scope. To the
maximum extent permitted by applicable law, the author and contributors
are not liable for data loss, security incidents, system damage, or
other damages caused by Sonbal or unexpected AI behavior.

Use Sonbal at your own risk.

## License

Sonbal uses the Zero-Clause BSD License (`0BSD`). See [LICENSE](LICENSE).
