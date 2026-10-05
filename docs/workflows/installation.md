# Sonbal Installation and Activation Workflow

## Scope

This document describes the current connector-only native deployment.

The package installs one Sonbal executable, the OpenAI connector shared library,
non-secret configuration, one native service definition, and the `sonbal`
non-login service identity. Package installation is activation-neutral.

Native packages also display the shared noninteractive Sonbal disclaimer during
installation/configuration. Debian emits the packaged notice from `postinst`;
FreeBSD carries the same notice as the package `+DISPLAY` message. The notice
warns about unexpected AI behavior, recommends isolation, warns against
sensitive-data exposure, and limits liability to the extent permitted by law.
It requests no input and does not enable or start the service.

## Runtime paths

Linux:

```text
/usr/bin/sonbal
/usr/lib/sonbal/connectors/libsonbal_connector_openai.so
/etc/sonbal/sonbal.yaml
/etc/sonbal/openai.json
/usr/lib/systemd/system/sonbal-openai.service
/var/lib/sonbal-openai/credential
```

FreeBSD:

```text
/usr/local/bin/sonbal
/usr/local/lib/sonbal/connectors/libsonbal_connector_openai.so
/usr/local/etc/sonbal/sonbal.yaml
/usr/local/etc/sonbal/openai.json
/usr/local/etc/rc.d/sonbal_openai
/var/db/sonbal-openai/credential
```

The package owns the executable, connector, configuration samples/files, and
service definition. It does not package the persistent credential.

## Sonbal configuration

The ordinary runtime configuration is:

```yaml
execution:
  max_work_slots: 16
```

The file is optional; missing configuration selects product defaults. Invalid,
oversized, unknown-key, unreadable, or out-of-range configuration fails before
MCP work is served.

## OpenAI provider configuration

`openai.json` contains only non-secret provider state. The packaged form is
fail-closed:

```json
{
  "tunnel_id": ""
}
```

Before activation, set the operator-owned tunnel identifier without adding
credentials or other secrets to this file.

## Credential installation

Linux keeps the persistent credential at
`/var/lib/sonbal-openai/credential`. The directory is root-owned mode `0700`
and the credential must be root:root mode `0600`.

FreeBSD keeps the persistent credential at
`/var/db/sonbal-openai/credential`. The directory is root:wheel mode `0700`
and the credential must be root:wheel mode `0600`.

Create the credential with a temporary file and atomic install rather than
placing the secret in a shell command line, environment variable, package
configuration, or world-readable staging path.

On Linux the systemd manager opens the credential and passes it as fd 3 through
the unit's single `OpenFile=` entry. On FreeBSD the root rc.d launcher opens
the credential as fd 3 before `daemon -u sonbal` performs the privilege
transition. The `sonbal` identity therefore consumes the already-open
descriptor without gaining pathname authority to the persistent secret.

## Linux activation

Validate package templates first:

```sh
rake linux-deployment-check
```

Installation does not enable or start `sonbal-openai.service`. After
configuration and credential provisioning, the operator may enable/start it
according to host policy.

Read-only acceptance probes are:

```sh
sudo -u sonbal rake linux-openai-service-running-check
sudo -u sonbal rake linux-openai-service-stopped-check
```

Run the first only after an explicit operator start and the second only after
an explicit operator stop. These tasks do not transition service state.

## FreeBSD activation

Validate the current templates natively:

```sh
rake freebsd-deployment-check
```

The rc.d service defaults to disabled. After configuration and credential
provisioning, explicitly enable/start `sonbal_openai` according to host
policy.

Read-only acceptance probes are:

```sh
sudo -u sonbal rake freebsd-openai-service-running-check
sudo -u sonbal rake freebsd-openai-service-stopped-check
```

The installed package state can be checked with:

```sh
sudo -u sonbal rake freebsd-installed-check
```

## Package checks

Debian:

```sh
rake debian-package
rake debian-package-check
rake debian-installed-check
```

FreeBSD:

```sh
rake freebsd-package
rake freebsd-package-check
rake freebsd-package-reproducibility-check
sudo -u sonbal rake freebsd-installed-check
```

Package builds use committed source snapshots and exact Clair provenance.
Root-required installation and service transitions remain operator-owned.

## Security preflight

```sh
sonbal --security-check
```

The preflight rejects known ambient credential variables and requires no
controlling terminal. It prints no credential values. It complements, but does
not replace, package/service permission checks.

## Direct stdio mode

Running `sonbal` with no connector argument starts the bounded stdio MCP
transport. This path is retained for direct integration and local workflows; it
does not require the native OpenAI service deployment.
