#!/usr/bin/env bash
#
# Proxmox MCP server -- one-shot installer for a fresh Debian 12/13 container.
#
# Installs a systemd service that exposes the Proxmox VE API as MCP tools over
# Streamable HTTP, listening on a port you point an MCP client at.
#
#     curl -fsSL <raw-url>/install.sh | sudo bash
#
# Asks for three things, or takes them as flags/env for a fully unattended run:
#
#     --proxmox-host  the Proxmox node                   (PROXMOX_HOST)
#     --token         PVEAPIToken=user@realm!id=secret   (PVE_TOKEN)
#     --client        IP allowed to reach the MCP port   (CLIENT_IP)
#
# Optional:
#     --port          listen port, default 8000          (MCP_PORT)
#     --api-key       inbound bearer token, default: generated  (MCP_API_KEY)
#     --no-firewall   skip the nftables allowlist
#
# Self-contained: it embeds the unit files, the dependency pins and the
# firewall rules, so it needs nothing from the repo but itself.
#
# Re-runnable. It will not overwrite an existing token, API key or CA.

set -euo pipefail

VERSION="0.5.18"                       # proxmox-mcp-plus release to install
SERVICE_USER="proxmox-mcp"
CONF_DIR="/etc/proxmox-mcp"
STATE_DIR="/var/lib/proxmox-mcp"
APP_DIR="/opt/proxmox-mcp"

MCP_PORT="${MCP_PORT:-8000}"
WITH_FIREWALL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxmox-host) PROXMOX_HOST="$2"; shift 2 ;;
    --token)        PVE_TOKEN="$2"; shift 2 ;;
    --client)       CLIENT_IP="$2"; shift 2 ;;
    --port)         MCP_PORT="$2"; shift 2 ;;
    --api-key)      MCP_API_KEY="$2"; shift 2 ;;
    --no-firewall)  WITH_FIREWALL=0; shift ;;
    -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# Piped through `curl | bash`, stdin is the script itself -- so prompts must
# read the terminal directly or they silently consume the rest of the script.
ask() {
  local __var="$1" __msg="$2" __default="${3:-}" __val=""
  [[ -n "${!__var:-}" ]] && return 0
  # `[[ -r /dev/tty ]]` is not enough: the path exists even with no controlling
  # terminal (cron, a pipeline with no tty, systemd), and the redirect then
  # fails with a raw shell error instead of something actionable. Probe it.
  ( : < /dev/tty ) 2>/dev/null || die "need a value for $__var but there is no terminal to ask on.
Pass it as a flag or environment variable for an unattended run:
  $0 --proxmox-host <ip> --token 'PVEAPIToken=...' --client <ip>"
  while [[ -z "$__val" ]]; do
    if [[ -n "$__default" ]]; then
      printf '    %s [%s]: ' "$__msg" "$__default" > /dev/tty
    else
      printf '    %s: ' "$__msg" > /dev/tty
    fi
    read -r __val < /dev/tty
    [[ -z "$__val" && -n "$__default" ]] && __val="$__default"
  done
  printf -v "$__var" '%s' "$__val"
}

# ------------------------------------------------------------------ preflight

[[ $EUID -eq 0 ]] || die "run as root:  wget -qO- <url> | sudo bash"

say "Preflight"
[[ -r /etc/os-release ]] && . /etc/os-release
note "OS: ${PRETTY_NAME:-unknown}"

command -v apt-get >/dev/null || die "this installer is for Debian/Ubuntu (no apt-get found)"

# A minimal container has neither python3 nor curl -- both are priority
# 'optional' in Debian, so a base root filesystem does not carry them. Pull
# python3 up front rather than at the package step, so an unsupported version
# fails before we bother asking any questions.
export DEBIAN_FRONTEND=noninteractive
if ! command -v python3 >/dev/null; then
  note "python3 not present -- installing it"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends python3 >/dev/null \
    || die "could not install python3 (apt-get failed)"
  command -v python3 >/dev/null \
    || die "apt-get reported success but python3 is still not on PATH"
fi

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' \
  || die "Python 3.11+ required (proxmox-mcp-plus sets requires-python >= 3.11); found $(python3 -V 2>&1)
Debian 12 ships 3.11 and Debian 13 ships 3.13. On anything older, use a newer base image."
note "Python: $(python3 -V 2>&1 | cut -d' ' -f2)"

# ------------------------------------------------------------------- questions

say "Configuration"
ask PROXMOX_HOST "Proxmox host (IP or hostname)"
ask PVE_TOKEN    "Proxmox API token (PVEAPIToken=user@realm!id=secret)"
[[ $WITH_FIREWALL -eq 1 ]] && ask CLIENT_IP "IP allowed to reach the MCP port (your MCP client)"

# Parse the token into the three values the server wants. Doing it here means
# the service needs no wrapper script at runtime.
PVE_TOKEN="${PVE_TOKEN//$'\n'/}"
[[ "$PVE_TOKEN" == PVEAPIToken=* ]] \
  || die "token must be in header form: PVEAPIToken=user@realm!tokenid=secret"
_body="${PVE_TOKEN#PVEAPIToken=}"
PVE_USER="${_body%%!*}"
_rest="${_body#*!}"
PVE_TOKEN_NAME="${_rest%%=*}"
PVE_TOKEN_VALUE="${_rest#*=}"
[[ -n "$PVE_USER" && -n "$PVE_TOKEN_NAME" && -n "$PVE_TOKEN_VALUE" && "$PVE_USER" == *@* ]] \
  || die "could not parse the token; expected PVEAPIToken=user@realm!tokenid=secret"
note "token: ${PVE_USER}!${PVE_TOKEN_NAME}"

# ----------------------------------------------------------------- packages

say "Packages"
apt-get update -qq
PKGS="python3 python3-venv ca-certificates curl openssl"
[[ $WITH_FIREWALL -eq 1 ]] && PKGS="$PKGS nftables"
apt-get install -y -qq --no-install-recommends $PKGS >/dev/null
note "$PKGS"

# amd64/arm64 have manylinux wheels for every native dependency. Anything else
# builds from source and needs a toolchain.
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  amd64|arm64|x86_64|aarch64) ;;
  *) note "no wheels for $ARCH -- installing build toolchain"
     apt-get install -y -qq --no-install-recommends \
       build-essential python3-dev libffi-dev libssl-dev cargo pkg-config >/dev/null ;;
esac

# -------------------------------------------------------- account and layout

say "Service account"
id -u "$SERVICE_USER" >/dev/null 2>&1 || \
  useradd --system --no-create-home --home-dir /nonexistent \
          --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -o root -g "$SERVICE_USER" -m 0750 "$CONF_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$STATE_DIR"
install -d -o root -g root -m 0755 "$APP_DIR"
note "$SERVICE_USER, $CONF_DIR, $STATE_DIR"

# ---------------------------------------------------------------- python env

say "Installing proxmox-mcp-plus $VERSION"
[[ -x "$APP_DIR/.venv/bin/python" ]] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -q --upgrade pip

# Fully pinned. --no-deps because the set below is complete and closed, so pip
# installs exactly this and resolves nothing -- which is what makes an install
# today and an install in six months identical.
cat > "$APP_DIR/requirements.lock" <<'LOCK'
annotated-doc==0.0.5
annotated-types==0.8.0
anyio==4.15.1
attrs==26.1.0
bcrypt==5.0.0
certifi==2026.7.22
cffi==2.1.1
charset-normalizer==3.5.1
click==8.5.0
cryptography==50.0.1
fastapi==0.141.1
h11==0.16.0
httpcore==1.0.9
httptools==0.8.0
httpx==0.28.1
httpx-sse==0.4.3
idna==3.20
invoke==3.0.3
jsonschema==4.26.0
jsonschema-specifications==2025.9.1
markdown-it-py==4.2.0
mcp==1.30.0
mcpo==0.0.20
mdurl==0.1.2
paramiko==5.0.0
passlib==1.7.4
proxmox-mcp-plus==0.5.18
proxmoxer==2.3.0
pycparser==3.0
pydantic==2.13.5
pydantic-settings==2.15.0
pydantic_core==2.46.5
Pygments==2.21.0
PyJWT==2.14.0
PyNaCl==1.6.2
python-dotenv==1.2.3
python-multipart==0.0.32
PyYAML==6.0.3
referencing==0.37.0
requests==2.34.2
rich==15.0.0
rpds-py==2026.6.3
shellingham==1.5.4
sse-starlette==3.4.11
starlette==1.6.0
typer==0.27.2
typing-inspection==0.4.4
typing_extensions==4.16.0
urllib3==2.8.0
uvicorn==0.53.0
uvloop==0.22.1
watchdog==6.0.0
watchfiles==1.2.0
websockets==17.1
LOCK

"$APP_DIR/.venv/bin/pip" install -q --no-deps -r "$APP_DIR/requirements.lock"
"$APP_DIR/.venv/bin/python" -c 'import proxmox_mcp.server' \
  || die "the installed package failed to import"
note "$APP_DIR/.venv"

# ------------------------------------------------------------------- the CA

# The server refuses verify_ssl=false unless dev_mode is also on, and running
# production in dev mode to dodge a self-signed cert is a bad trade. So pin
# Proxmox's own cluster CA and keep verification on.
say "Proxmox TLS"
if [[ ! -s "$CONF_DIR/pve-ca.pem" ]]; then
  NODE="$(curl -sk --max-time 15 -H "Authorization: $PVE_TOKEN" \
    "https://$PROXMOX_HOST:8006/api2/json/nodes" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
print(d[0]["node"] if d else "")' 2>/dev/null)" || true
  [[ -n "$NODE" ]] || die "could not list nodes on $PROXMOX_HOST.
Either the host is wrong, or the token has no privileges -- see README,
'the gotcha that catches everyone'."

  curl -sk --max-time 15 -H "Authorization: $PVE_TOKEN" \
    "https://$PROXMOX_HOST:8006/api2/json/nodes/$NODE/certificates/info" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
m=[c for c in d if c.get("filename")=="pve-root-ca.pem"]
sys.stdout.write(m[0]["pem"] if m else "")' > "$CONF_DIR/pve-ca.pem"

  [[ -s "$CONF_DIR/pve-ca.pem" ]] || die "could not retrieve the Proxmox CA"
  chmod 0644 "$CONF_DIR/pve-ca.pem"
  note "node: $NODE"
  note "CA fingerprint (compare on the host with:"
  note "  openssl x509 -in /etc/pve/pve-root-ca.pem -noout -fingerprint -sha256)"
  note "  $(openssl x509 -in "$CONF_DIR/pve-ca.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
else
  note "$CONF_DIR/pve-ca.pem exists; left untouched"
fi

# --------------------------------------------------------- validate the token

# Do this before writing config: a token that authenticates but has no rights
# is the single most common way this ends up "installed but broken", and it
# reports success at every layer that only checks status codes.
say "Checking the token"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  --cacert "$CONF_DIR/pve-ca.pem" -H "Authorization: $PVE_TOKEN" \
  "https://$PROXMOX_HOST:8006/api2/json/version")" || true
[[ "$CODE" == "200" ]] || die "Proxmox returned $CODE for /version.
401 means the credential itself is rejected: wrong realm (@pam vs @pve),
wrong secret, or a disabled account."
note "authenticates (200)"

NODE_COUNT="$(curl -s --max-time 15 --cacert "$CONF_DIR/pve-ca.pem" \
  -H "Authorization: $PVE_TOKEN" "https://$PROXMOX_HOST:8006/api2/json/nodes" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("data") or []))')" || true
[[ "${NODE_COUNT:-0}" -gt 0 ]] || die "the token authenticates but can see no nodes.
Proxmox filters results rather than refusing, so this returns 200 with an empty
list and looks like success. You almost certainly granted Administrator to the
token but not to the user -- see README, 'the gotcha that catches everyone'."
note "sees $NODE_COUNT node(s) -- privileges are real"

# -------------------------------------------------------------- bearer token

if [[ -s "$CONF_DIR/mcp-api-key" ]]; then
  MCP_API_KEY="$(cat "$CONF_DIR/mcp-api-key")"
  KEY_IS_NEW=0
else
  MCP_API_KEY="${MCP_API_KEY:-$(openssl rand -hex 32)}"
  ( umask 077; printf '%s' "$MCP_API_KEY" > "$CONF_DIR/mcp-api-key" )
  chown root:"$SERVICE_USER" "$CONF_DIR/mcp-api-key"; chmod 0640 "$CONF_DIR/mcp-api-key"
  KEY_IS_NEW=1
fi

# -------------------------------------------------------------------- config

say "Writing configuration"
umask 077
cat > "$CONF_DIR/proxmox-mcp.env" <<ENV
# Written by install.sh. Contains secrets -- mode 0640, root:$SERVICE_USER.

PROXMOX_HOST=$PROXMOX_HOST
PROXMOX_PORT=8006
PROXMOX_VERIFY_SSL=true
PROXMOX_USER=$PVE_USER
PROXMOX_TOKEN_NAME=$PVE_TOKEN_NAME
PROXMOX_TOKEN_VALUE=$PVE_TOKEN_VALUE

# Verify Proxmox against its own pinned cluster CA rather than disabling TLS.
REQUESTS_CA_BUNDLE=$CONF_DIR/pve-ca.pem
SSL_CERT_FILE=$CONF_DIR/pve-ca.pem

# Streamable HTTP. MCP_API_KEY is the bearer token clients must present --
# without it the server would serve Administrator-level tools to anyone who
# can reach the port.
MCP_TRANSPORT=STREAMABLE
MCP_HOST=0.0.0.0
MCP_PORT=$MCP_PORT
MCP_API_KEY=$MCP_API_KEY

LOG_LEVEL=INFO
PROXMOX_JOBS_SQLITE_PATH=$STATE_DIR/proxmox-jobs.sqlite3

# Guest shell execution. deny_all unless you have a specific reason.
COMMAND_POLICY_MODE=deny_all

# Optional: refuse to expose these tools at all, to any client.
#MCP_TOOL_DENYLIST=delete_vm,delete_container,delete_snapshot,delete_backup
ENV
chown root:"$SERVICE_USER" "$CONF_DIR/proxmox-mcp.env"
chmod 0640 "$CONF_DIR/proxmox-mcp.env"
umask 022
note "$CONF_DIR/proxmox-mcp.env"

# ------------------------------------------------------------------ firewall

if [[ $WITH_FIREWALL -eq 1 ]]; then
  say "Port allowlist"
  if [[ ! -s "$CONF_DIR/firewall.nft" ]]; then
    cat > "$CONF_DIR/firewall.nft" <<NFT
#!/usr/sbin/nft -f
# Written by install.sh. Reload after editing:
#     systemctl reload proxmox-mcp-firewall
#
# Its own table: netfilter evaluates every table and a drop in any one wins,
# so this coexists with whatever else manages the firewall here.
table inet proxmox_mcp {
	set allowed_clients {
		type ipv4_addr
		flags interval
		elements = { $CLIENT_IP }
	}

	chain input {
		# policy accept, scoped to one port. A drop policy here would drop
		# SSH too, and you would find out the hard way.
		type filter hook input priority filter; policy accept;

		iif lo tcp dport $MCP_PORT accept
		ct state established,related tcp dport $MCP_PORT accept
		ip saddr @allowed_clients tcp dport $MCP_PORT accept
		tcp dport $MCP_PORT counter reject with tcp reset
	}
}
NFT
    chmod 0644 "$CONF_DIR/firewall.nft"
    note "allowing $CLIENT_IP -> port $MCP_PORT"
  else
    note "$CONF_DIR/firewall.nft exists; left untouched"
  fi

  cat > /etc/systemd/system/proxmox-mcp-firewall.service <<'FWUNIT'
[Unit]
Description=Proxmox MCP port allowlist (nftables)
After=network-pre.target
Wants=network-pre.target
Before=proxmox-mcp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/nft -c -f /etc/proxmox-mcp/firewall.nft
ExecStart=/usr/sbin/nft -f /etc/proxmox-mcp/firewall.nft
# nft -f merges into an existing table, so delete first -- otherwise a client
# you removed from the allowlist stays allowed until reboot.
ExecReload=/bin/sh -c '/usr/sbin/nft -c -f /etc/proxmox-mcp/firewall.nft && /usr/sbin/nft delete table inet proxmox_mcp 2>/dev/null; /usr/sbin/nft -f /etc/proxmox-mcp/firewall.nft'
ExecStop=-/usr/sbin/nft delete table inet proxmox_mcp

[Install]
WantedBy=multi-user.target
FWUNIT
  nft -c -f "$CONF_DIR/firewall.nft" || die "the generated ruleset does not validate"
fi

# ------------------------------------------------------------------- service

say "systemd"
{
cat <<UNIT
[Unit]
Description=Proxmox MCP server
After=network-online.target
Wants=network-online.target
UNIT
[[ $WITH_FIREWALL -eq 1 ]] && cat <<'UNIT'
# The allowlist is the only network-level control, so a ruleset that fails to
# load must stop the server starting rather than leave the port open.
Requires=proxmox-mcp-firewall.service
After=proxmox-mcp-firewall.service
PartOf=proxmox-mcp-firewall.service
UNIT
cat <<UNIT
# These belong in [Unit]; systemd silently ignores them in [Service].
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=exec
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$STATE_DIR
EnvironmentFile=$CONF_DIR/proxmox-mcp.env
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/.venv/bin/proxmox-mcp

Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=proxmox-mcp

# This process holds an Administrator credential for the whole Proxmox host.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
UMask=0077
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
UNIT
} > /etc/systemd/system/proxmox-mcp.service

systemctl daemon-reload
[[ $WITH_FIREWALL -eq 1 ]] && systemctl enable --now proxmox-mcp-firewall >/dev/null 2>&1
systemctl enable proxmox-mcp >/dev/null 2>&1
systemctl restart proxmox-mcp
note "proxmox-mcp.service started"

# -------------------------------------------------------------------- verify

say "Verifying"
for _ in $(seq 1 20); do
  ss -lnt 2>/dev/null | grep -q ":$MCP_PORT " && break
  sleep 1
done

systemctl is-active --quiet proxmox-mcp \
  || die "the service is not running. journalctl -u proxmox-mcp -n 50"

# Unauthenticated request must be refused. If this returns anything but 401
# the bearer middleware is not in force, and the port is an open door.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST "http://127.0.0.1:$MCP_PORT/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')" || true
[[ "$CODE" == "401" ]] \
  || die "expected 401 without a token, got '$CODE'. The endpoint may be unauthenticated -- stop and investigate."
note "listening on $MCP_PORT, rejects unauthenticated requests (401)"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

  Endpoint    http://${IP:-<this-host>}:$MCP_PORT/mcp
  Bearer      $MCP_API_KEY
EOF
[[ $KEY_IS_NEW -eq 0 ]] && echo "              (existing key, reused)"
[[ $WITH_FIREWALL -eq 1 ]] && echo "  Allowed     $CLIENT_IP"
cat <<EOF

  Point your MCP client at that URL with header:
      Authorization: Bearer <the token above>

  Anything holding that token has Administrator on $PROXMOX_HOST, and the
  token crosses the network in cleartext. Keep it on a trusted segment.

  logs      journalctl -u proxmox-mcp -f
  config    $CONF_DIR/proxmox-mcp.env
  allowlist $CONF_DIR/firewall.nft   (systemctl reload proxmox-mcp-firewall)

EOF
