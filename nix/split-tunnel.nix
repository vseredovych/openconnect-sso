# Split-tunnel VPN command built on openconnect-sso + openconnect + vpn-slice.
#
# Produces two programs:
#   <name>          user-facing CLI: up | down | status | log
#   <name>-helper   the only part that runs as root; validates every argument
#
# Connection details (gateway, DNS, domains, routes) are private and are read at runtime
# from configFile, so they never end up in the Nix store.
{ lib
, writeShellScriptBin
, writeShellScript
, openconnect
, vpn-slice
, openconnect-sso
, name
, configFile
, allowLegacyTls ? false
, acVersion ? "4.7.00136"
}:

let
  pidFile = "/var/run/${name}.pid";
  hostFile = "/var/run/${name}.host";
  logFile = "/var/log/${name}.log";

  # Called by openconnect on connect/disconnect: <dns,...> <domain,...> <route>...
  # vpn-slice resolves ifconfig/route/pfctl via PATH first; use the macOS system tools
  # (a GNU ifconfig from e.g. inetutils takes different arguments).
  sliceHook = writeShellScript "${name}-vpn-slice" ''
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export INTERNAL_IP4_DNS="''${1//,/ }"
    domains="$2"
    shift 2
    ${vpn-slice}/bin/vpn-slice --domains-vpn-dns "$domains" "$@" || exit

    # vpn-slice pins a host route to the gateway via the router of the network we're on
    # now. After a network change (sleep, other Wi-Fi) that router is gone and every
    # reconnect fails ("Can't assign requested address"). With a split tunnel the pin is
    # only needed if a VPN route covers the gateway, so drop it otherwise and let the
    # gateway follow the current default route.
    ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
    covered() {
      local gw net bits
      gw="$(ip2int "$1")"; shift
      for route in "$@"; do
        [[ "$route" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(/([0-9]+))?$ ]] || continue
        net="$(ip2int "''${BASH_REMATCH[1]}")"; bits="''${BASH_REMATCH[3]:-32}"
        (( bits == 0 || (gw ^ net) >> (32 - bits) == 0 )) && return 0
      done
      return 1
    }
    if [[ "''${reason:-}" == connect && "''${VPNGATEWAY:-}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] \
      && ! covered "$VPNGATEWAY" "$@"; then
      route -n delete -host "$VPNGATEWAY" >/dev/null 2>&1 || true
    fi
  '';

  helper = writeShellScript "${name}-helper" ''
    set -euo pipefail
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin

    fail() { echo "${name}: $*" >&2; exit 2; }

    running() {
      [[ -f ${pidFile} ]] || return 1
      pid="$(<${pidFile})"
      [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o comm= | grep -q openconnect
    }

    case "''${1:-}" in
      up)
        [[ $# -ge 6 ]] || fail "usage: up URL FINGERPRINT DNS,... DOMAIN,... ROUTE..."
        url="$2" fingerprint="$3" dns="$4" domains="$5"
        shift 5
        [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || fail "invalid URL: $url"
        [[ "$fingerprint" =~ ^[A-Za-z0-9:=+/_-]+$ ]] || fail "invalid server fingerprint"
        [[ "$dns" =~ ^[0-9A-Fa-f.:,]+$ ]] || fail "invalid DNS list: $dns"
        [[ "$domains" =~ ^[A-Za-z0-9.,-]+$ ]] || fail "invalid domain list: $domains"
        for route in "$@"; do
          [[ "$route" =~ ^[A-Za-z0-9][A-Za-z0-9.:/-]*$ ]] || fail "invalid route: $route"
        done
        IFS= read -r cookie || true
        [[ -n "$cookie" ]] || fail "no session cookie on stdin"
        running && fail "already connected"

        echo "=== $(date '+%F %T') connecting to $url" >>${logFile}
        chmod 644 ${logFile}
        if ! ${openconnect}/bin/openconnect \
          --background \
          --pid-file=${pidFile} \
          --protocol=anyconnect \
          --useragent="AnyConnect Linux_64 ${acVersion}" \
          --version-string=${acVersion} \
          --servercert="$fingerprint" \
          --cookie-on-stdin \
          --script="${sliceHook} $dns $domains $*" \
          "$url" <<<"$cookie" >>${logFile} 2>&1
        then
          tail -n 5 ${logFile} >&2
          exit 1
        fi
        echo "$url" >${hostFile}
        ;;
      down)
        if running; then
          # Clean shutdown first (logs the session off, vpn-slice cleans up); that can hang
          # when the tunnel is already dead, so escalate.
          for sig in INT TERM KILL; do
            kill -"$sig" "$pid" 2>/dev/null || true
            for _ in $(seq 25); do running || break 2; sleep 0.2; done
          done
          running && fail "openconnect (pid $pid) did not exit"
        fi
        rm -f ${pidFile} ${hostFile}
        ;;
      *)
        fail "usage: up URL FINGERPRINT DNS DOMAINS ROUTE... | down"
        ;;
    esac
  '';

  cli = writeShellScriptBin name ''
    set -uo pipefail

    usage() {
      cat <<EOF
    usage: ${name} [up [HOST]] | down | status | log

      up [HOST]  log in (SSO window) and connect; HOST overrides SERVER from the config
      down       disconnect
      status     print the connection state (exit 0 if connected)
      log        follow the connection log

    Config: ${configFile}
    EOF
    }

    process_alive() {
      local pid
      pid="$(cat ${pidFile} 2>/dev/null)" || return 1
      [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o comm= 2>/dev/null | grep -q openconnect
    }

    # Tunnel state since the last connect, from openconnect's log: ok | reconnecting | failed.
    # (DTLS dead peer alone is fine: openconnect falls back to the TLS channel.)
    tunnel_state() {
      awk '
        /^=== /                                                   { s = "ok" }
        /CSTP connected|Configured as/                            { s = "ok" }
        /CSTP Dead Peer Detection|Failed to reconnect|remaining timeout/ { s = "reconnecting" }
        /Reconnect failed/                                        { s = "failed" }
        END { print s }
      ' ${logFile} 2>/dev/null
    }

    # exit 0: connected, 1: disconnected, 3: openconnect is trying to reconnect
    status() {
      if ! process_alive; then
        echo "Disconnected"
        return 1
      fi
      local url
      url="$(cat ${hostFile} 2>/dev/null)"
      url="''${url#https://}"
      url="''${url%%/*}"
      case "$(tunnel_state)" in
        reconnecting) echo "Reconnecting to $url (tunnel down)"; return 3 ;;
        failed) echo "Disconnected (reconnect to $url failed)"; return 1 ;;
        *) echo "Connected to $url" ;;
      esac
    }

    up() {
      if status >/dev/null; then
        status
        return 0
      fi
      # Clear out a dead or still-reconnecting session first.
      process_alive && { /usr/bin/sudo ${helper} down || return 1; }

      local config="${configFile}"
      if [[ ! -r "$config" ]]; then
        cat >&2 <<EOF
    ${name}: missing $config. Create it (chmod 600) with:

      SERVER=vpn.example.com
      AUTHGROUP=GROUP-NAME
      DNS="10.0.0.53 10.0.1.53"
      DOMAINS="corp.example.com example.internal"
      ROUTES="10.0.0.0/16 192.0.2.0/24"
    EOF
        return 1
      fi
      local SERVER="" AUTHGROUP="" DNS="" DOMAINS="" ROUTES=""
      source "$config"

      local server="''${1:-$SERVER}"
      [[ -n "$server" && -n "$DNS" && -n "$DOMAINS" && -n "$ROUTES" ]] \
        || { echo "${name}: SERVER, DNS, DOMAINS and ROUTES must be set in $config" >&2; return 1; }

      # SSO login as the user; keep only the HOST/COOKIE/FINGERPRINT lines.
      local auth HOST="" COOKIE="" FINGERPRINT=""
      auth="$(${openconnect-sso}/bin/openconnect-sso \
        --server "$server" ''${AUTHGROUP:+--authgroup "$AUTHGROUP"} \
        --ac-version ${acVersion} ${lib.optionalString allowLegacyTls "--allow-legacy-tls"} \
        --authenticate shell)" || return 1
      eval "$(grep -E '^(HOST|COOKIE|FINGERPRINT)=' <<<"$auth")"
      [[ -n "$COOKIE" ]] || { echo "${name}: login did not return a session cookie" >&2; return 1; }

      # shellcheck disable=SC2086 # ROUTES is a space-separated list
      /usr/bin/sudo ${helper} up "$HOST" "$FINGERPRINT" "''${DNS// /,}" "''${DOMAINS// /,}" $ROUTES <<<"$COOKIE" \
        || return 1
      status
    }

    case "''${1:-up}" in
      up) shift || true; up "$@" ;;
      down) /usr/bin/sudo ${helper} down && echo "Disconnected" ;;
      status) status ;;
      log) exec tail -n 50 -F ${logFile} ;;
      -h|--help|help) usage ;;
      *) usage >&2; exit 1 ;;
    esac
  '';
in
{
  inherit cli helper logFile;
}
