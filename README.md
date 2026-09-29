# openconnect-sso

Wrapper script for OpenConnect supporting Azure AD (SAMLv2) authentication
to Cisco SSL-VPNs

[![Tests Status
](https://github.com/vlaci/openconnect-sso/workflows/Tests/badge.svg?branch=master&event=push)](https://github.com/vlaci/openconnect-sso/actions?query=workflow%3ATests+branch%3Amaster+event%3Apush)

## Installation

### Using pip/pipx

A generic way that works on most 'standard' Linux distributions out of the box.
The following example shows how to install `openconect-sso` along with its
dependencies including Qt:

```shell
$ pip install --user pipx
Successfully installed pipx
$ pipx install "openconnect-sso[full]"
⣾ installing openconnect-sso
  installed package openconnect-sso 0.4.0, Python 3.7.5
  These apps are now globally available
    - openconnect-sso
⚠️  Note: '/home/vlaci/.local/bin' is not on your PATH environment variable.
These apps will not be globally accessible until your PATH is updated. Run
`pipx ensurepath` to automatically add it, or manually modify your PATH in your
shell's config file (i.e. ~/.bashrc).
done! ✨ 🌟 ✨
Successfully installed openconnect-sso
$ pipx ensurepath
Success! Added /home/vlaci/.local/bin to the PATH environment variable.
Consider adding shell completions for pipx. Run 'pipx completions' for
instructions.

You likely need to open a new terminal or re-login for the changes to take
effect. ✨ 🌟 ✨
```

Of course you can also install via `pip` instead of `pipx` if you'd like to
install system-wide or a virtualenv of your choice.

### On Arch Linux

There is an unofficial package available for Arch Linux on
[AUR](https://aur.archlinux.org/packages/openconnect-sso/). You can use your
favorite AUR helper to install it:

``` shell
yay -S openconnect-sso
```

### Using nix

The flake provides the package, an overlay and a nix-darwin module:

```shell
$ nix run github:vseredovych/openconnect-sso -- --server vpn.example.com
```

``` nix
{
  inputs.openconnect-sso.url = "github:vseredovych/openconnect-sso";
  # packages.<system>.default, overlays.default, darwinModules.default
}
```

### macOS (nix-darwin): split tunnel + menu bar

`darwinModules.default` adds a split-tunnel VPN command and an optional menu bar icon:

``` nix
{
  imports = [ inputs.openconnect-sso.darwinModules.default ];

  programs.openconnect-sso = {
    enable = true;
    splitTunnel = {
      enable = true;
      name = "work-vpn";         # command: work-vpn up | down | status | log
      # allowLegacyTls = true;   # only for gateways without modern TLS, see below
    };
    menubar.enable = true;       # lock icon in the menu bar, started at login
  };
}
```

The connection details stay private, out of the Nix store, in `~/.config/<name>/config`:

```shell
SERVER=vpn.example.com
AUTHGROUP=GROUP-NAME
DNS="10.0.0.53 10.0.1.53"                  # used only for DOMAINS (macOS /etc/resolver)
DOMAINS="corp.example.com example.internal"
ROUTES="10.0.0.0/16 192.0.2.0/24"          # only these go through the VPN
```

`<name> up` opens the SSO window, then runs `openconnect` in the background with
[vpn-slice](https://github.com/dlenski/vpn-slice) as its script. Only a small root helper
runs as root; it validates its arguments, and the module lets `system.primaryUser` run it
without a password so the menu bar can connect. Logs: `<name> log`.

The login window keeps its own on-disk profile (`~/.local/share/openconnect-sso/webengine`),
so answering *Stay signed in? → Yes* once lets later logins skip the password and MFA,
as far as the identity provider's policy allows. Delete that directory to forget it.

#### Legacy TLS gateways

Some gateways only offer TLS ciphers without forward secrecy (`TLS_RSA_*`, CBC-SHA1).
Python rejects those by default, so the login fails with an `SSL ... handshake failure`.
`--allow-legacy-tls` (or `allowLegacyTls = true`) accepts them, and legacy renegotiation,
**for the gateway's host only**. Certificates and host names are still verified. OpenConnect
itself already accepts these ciphers for the tunnel. Each run logs a warning, and the module
adds an evaluation warning, until you turn it off.

### Windows *(EXPERIMENTAL)*

Install with [pip/pipx](#using-pippipx) and be sure that you have `sudo` and `openconnect`
executable commands in your PATH.

## Usage

If you want to save credentials and get them automatically
injected in the web browser:

```shell
$ openconnect-sso --server vpn.server.com/group --user user@domain.com
Password (user@domain.com):
[info     ] Authenticating to VPN endpoint ...
```

User credentials are automatically saved to the users login keyring (if
available).

If you already have Cisco AnyConnect set-up, then `--server` argument is
optional. Also, the last used `--server` address is saved between sessions so
there is no need to always type in the same arguments:

```shell
$ openconnect-sso
[info     ] Authenticating to VPN endpoint ...
```

Configuration is saved in `$XDG_CONFIG_HOME/openconnect-sso/config.toml`. On
typical Linux installations it is located under
`$HOME/.config/openconnect-sso/config.toml`

For CISCO-VPN and TOTP the following seems to work by tuning the config.toml
and removing the default "submit"-action to the following:

```
[[auto_fill_rules."https://*"]]
selector = "input[data-report-event=Signin_Submit]"
action = "click"

[[auto_fill_rules."https://*"]]
selector = "input[type=tel]"
fill = "totp"
```

### Adding custom `openconnect` arguments

Sometimes you need to add custom `openconnect` arguments. One situation can be if you get similar error messages:

```shell
Failed to read from SSL socket: The transmitted packet is too large (EMSGSIZE).
Failed to recv DPD request (-5)
```

or:

```shell
Detected MTU of 1370 bytes (was 1406)
```

Generally, you can add `openconnect` arguments after the `--` separator. This is called _"positional arguments"_. The
solution of the previous errors is setting `--base-mtu` e.g.:

```shell
openconnect-sso --server vpn.server.com/group --user user@domain.com -- --base-mtu=1370
#                                                          separator ^^|^^^^^^^^^^^^^^^ openconnect args
```

## Development

`openconnect-sso` is developed using [Nix](https://nixos.org/nix/). Refer to the
[Quick Start section of the Nix
manual](https://nixos.org/nix/manual/#chap-quick-start) to see how to get it
installed on your machine.

To get dropped into a development environment, just type `nix-shell`:

```shell
$ nix-shell
Sourcing python-catch-conflicts-hook.sh
Sourcing python-remove-bin-bytecode-hook.sh
Sourcing pip-build-hook
Using pipBuildPhase
Sourcing pip-install-hook
Using pipInstallPhase
Sourcing python-imports-check-hook.sh
Using pythonImportsCheckPhase
Run 'make help' for available commands

[nix-shell]$
```

To try an installed version of the package, issue `nix-build`:

```shell
$ nix build
[1 built, 0.0 MiB DL]

$ result/bin/openconnect-sso --help
```

Alternatively you may just [get Poetry](https://python-poetry.org/docs/) and
start developing by using the included `Makefile`. Type `make help` to see the
possible make targets.
