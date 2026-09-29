self:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.openconnect-sso;
  vpn = cfg.splitTunnel;

  splitTunnel = pkgs.callPackage ./split-tunnel.nix {
    openconnect-sso = cfg.package;
    inherit (vpn) name allowLegacyTls;
    configFile = if vpn.configFile != null then vpn.configFile else "$HOME/.config/${vpn.name}/config";
  };

  menubarLabel = "org.nixos.openconnect-sso-menubar";

  # "<title>.app" in /Applications/Nix Apps, so the menu bar icon can be brought back
  # (Spotlight, Raycast, Finder) after "Quit". It just starts the login item, which
  # launchd keeps to a single instance.
  menubarApp = pkgs.runCommand "openconnect-sso-menubar-app" { } ''
    app="$out/Applications/${cfg.menubar.title}.app/Contents"
    mkdir -p "$app/MacOS"
    cat >"$app/Info.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key><string>${cfg.menubar.title}</string>
      <key>CFBundleIdentifier</key><string>${menubarLabel}.launcher</string>
      <key>CFBundleExecutable</key><string>launcher</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleVersion</key><string>${cfg.package.version}</string>
      <key>LSUIElement</key><true/>
    </dict>
    </plist>
    EOF
    cat >"$app/MacOS/launcher" <<'EOF'
    #!/bin/sh
    exec /bin/launchctl kickstart "gui/$(/usr/bin/id -u)/${menubarLabel}"
    EOF
    chmod +x "$app/MacOS/launcher"
  '';
in
{
  options.programs.openconnect-sso = {
    enable = lib.mkEnableOption "openconnect-sso, OpenConnect with Azure AD (SAMLv2) login";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.openconnect-sso;
      description = "The openconnect-sso package.";
    };

    splitTunnel = {
      enable = lib.mkEnableOption ''
        a split-tunnel VPN command (`<name> up|down|status|log`) that only routes the
        configured subnets and DNS domains through the VPN, using vpn-slice.
        The connection details are read at runtime from `configFile`, so they stay out
        of the Nix store. Lets `system.primaryUser` run its root helper without a password'';

      name = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+";
        default = "vpn";
        description = "Name of the command, and of its config directory, pid and log files.";
      };

      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Private connection config, read at runtime. Defaults to `$HOME/.config/<name>/config`.";
      };

      allowLegacyTls = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Pass `--allow-legacy-tls` to openconnect-sso: accept TLS ciphers without forward
          secrecy (TLS_RSA, CBC-SHA1) and legacy renegotiation for the gateway only.
          Certificates are still verified. Only enable this for gateways that support
          nothing newer.
        '';
      };
    };

    menubar = {
      enable = lib.mkEnableOption "a menu bar icon to connect/disconnect the split-tunnel VPN, started at login";

      title = lib.mkOption {
        type = lib.types.str;
        default = "VPN";
        description = "Name shown in the menu.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ cfg.package ];
    }

    (lib.mkIf vpn.enable {
      environment.systemPackages = [ splitTunnel.cli pkgs.openconnect ];

      # Needed by the menu bar (no terminal to type a password into). The helper only
      # accepts validated arguments and only runs openconnect with the fixed hook.
      security.sudo.extraConfig = ''
        ${config.system.primaryUser} ALL=(root) NOPASSWD: ${splitTunnel.helper}
      '';

      warnings = lib.optional vpn.allowLegacyTls ''
        programs.openconnect-sso.splitTunnel.allowLegacyTls is enabled: the SSO login to
        the gateway accepts TLS without forward secrecy (TLS_RSA, CBC-SHA1). Certificates
        are still verified. Disable it once the gateway supports modern TLS.
      '';
    })

    (lib.mkIf cfg.menubar.enable {
      assertions = [{
        assertion = vpn.enable;
        message = "programs.openconnect-sso.menubar requires programs.openconnect-sso.splitTunnel.enable.";
      }];

      environment.systemPackages = [ menubarApp ];

      launchd.user.agents.openconnect-sso-menubar.serviceConfig = {
        ProgramArguments = [
          "${cfg.package}/bin/openconnect-sso-menubar"
          "--command" "${splitTunnel.cli}/bin/${vpn.name}"
          "--name" cfg.menubar.title
          "--log" splitTunnel.logFile
        ];
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false; # restart after a crash, not after "Quit"
        ProcessType = "Interactive";
        LimitLoadToSessionType = "Aqua";
        StandardErrorPath = "/tmp/openconnect-sso-menubar.log";
      };
    })
  ]);
}
