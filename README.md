# openconnect-sso

Wrapper for OpenConnect supporting Azure AD (SAMLv2) authentication to Cisco SSL-VPNs.

> **This is a fork** of [vlaci/openconnect-sso](https://github.com/vlaci/openconnect-sso)
> (unmaintained since 2023), focused on macOS + Nix. Packages on PyPI and AUR are the
> upstream version, not this fork.

## What's different from upstream

- **Remembers the sign-in.** The login window keeps an on-disk profile
  (`~/.local/share/openconnect-sso/webengine`), so answering *Stay signed in? → Yes* once
  lets later logins skip the password and MFA, as far as the identity provider allows.
  The gateway's one-time SSO cookies are cleared after each login.
- **`--allow-legacy-tls`** for gateways that only offer old ciphers (see below).
- **Split-tunnel command and menu bar icon for macOS**, via a nix-darwin module.
- **Fixes:** Python 3.14 support, `pkg_resources` removed, auth URL detection that works
  with gateways that reject AnyConnect headers on the first request.
- **Nix flake** built from nixpkgs packages (replaces niv/poetry2nix).

## Install

```shell
nix run github:vseredovych/openconnect-sso -- --server vpn.example.com
```

The flake exports `packages.<system>.default`, `overlays.default` and
`darwinModules.default`.

## macOS: split tunnel + menu bar (nix-darwin)

```nix
# flake.nix
inputs.openconnect-sso.url = "github:vseredovych/openconnect-sso";

# darwin configuration
imports = [ inputs.openconnect-sso.darwinModules.default ];

programs.openconnect-sso = {
  enable = true;
  splitTunnel = {
    enable = true;
    name = "work-vpn";        # command: work-vpn up | down | status | log
    # allowLegacyTls = true;  # only if the gateway needs it, see below
  };
  menubar.enable = true;      # lock icon in the menu bar, started at login
};
```

Connection details stay private, outside the Nix store, in `~/.config/<name>/config`:

```shell
SERVER=vpn.example.com
AUTHGROUP=GROUP-NAME
DNS="10.0.0.53 10.0.1.53"                  # used only for DOMAINS
DOMAINS="corp.example.com example.internal"
ROUTES="10.0.0.0/16 192.0.2.0/24"          # only these go through the VPN
```

`<name> up` opens the login window, then runs `openconnect` in the background with
[vpn-slice](https://github.com/dlenski/vpn-slice), so only `ROUTES` and `DOMAINS` use the
VPN. The only part that runs as root is a small helper that validates its arguments; the
module lets `system.primaryUser` run it without a password, so the menu bar can connect.

## Legacy TLS gateways

Some gateways only offer ciphers without forward secrecy (`TLS_RSA_*`, CBC-SHA1), and the
login fails with `SSL ... handshake failure`. `--allow-legacy-tls` (module:
`allowLegacyTls = true`) accepts them, plus legacy renegotiation, **for the gateway's host
only**. Certificates and host names are still verified, and OpenConnect already accepts
these ciphers for the tunnel. It's opt-in and logs a warning on every login.

## Usage

```shell
openconnect-sso --server vpn.example.com/group
openconnect-sso --server vpn.example.com --authenticate shell   # print HOST/COOKIE/FINGERPRINT only
openconnect-sso --server vpn.example.com -- --base-mtu=1370     # extra openconnect arguments after --
```

The last server is saved in `~/.config/openconnect-sso/config.toml`, so later runs can
omit `--server`. `--user user@example.com` saves the password in the login keyring and
fills it in automatically. See `openconnect-sso --help` for all options.

## Development

```shell
nix develop      # Python, Qt and test dependencies
nix build        # result/bin/openconnect-sso
```
