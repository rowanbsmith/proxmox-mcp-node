#!/usr/bin/env bash
#
# Proxmox MCP server -- one-shot installer for a fresh Debian 12/13 container.
#
# Installs a systemd service that exposes the Proxmox VE API as MCP tools over
# Streamable HTTP, listening on a port you point an MCP client at.
#
#     wget -qO- <raw-url>/install.sh | sudo bash
#
# Asks four things, or takes them as flags/env for a fully unattended run:
#
#     --proxmox-host  the Proxmox node                   (PROXMOX_HOST)
#     --token-id      user@realm!tokenid                 (TOKEN_ID)
#     --secret        the token secret                   (TOKEN_SECRET)
#     --client        IPs allowed to reach the MCP port  (CLIENT_IP)
#
# Token ID and secret are the two fields the Proxmox GUI shows you.
#
# Optional:
#     --token         the two pre-assembled as a header  (PVE_TOKEN)
#     --port          listen port, default 8000          (MCP_PORT)
#     --api-key       inbound bearer token, default: generated  (MCP_API_KEY)
#     --no-firewall   skip the nftables allowlist
#
# Self-contained: it embeds the unit files, the dependency pins and the
# firewall rules, so it needs nothing from the repo but itself.
#
# Re-runnable. It will not overwrite an existing token, API key or CA.

set -euo pipefail

MCP_PLUS_VERSION="0.5.18"              # proxmox-mcp-plus release to install
# NB: do not call this VERSION. Preflight sources /etc/os-release, which
# defines VERSION ("13 (trixie)") and would silently overwrite it.
SERVICE_USER="proxmox-mcp"
CONF_DIR="/etc/proxmox-mcp"
STATE_DIR="/var/lib/proxmox-mcp"
APP_DIR="/opt/proxmox-mcp"

MCP_PORT="${MCP_PORT:-8000}"
WITH_FIREWALL=1

# Embedded rather than read back out of "$0": piped through `bash -s --`, $0 is
# "bash" and there is no file to read.
usage() {
  cat <<'USAGE'
Proxmox MCP server installer.

  wget -qO- <url>/install.sh | sudo bash                  interactive
  wget -qO- <url>/install.sh | sudo bash -s -- [options]  unattended

Options (or pass as environment variables):

  --proxmox-host HOST   Proxmox node, IP or hostname        (PROXMOX_HOST)
  --token-id ID         user@realm!tokenid                  (TOKEN_ID)
  --secret UUID         the token secret                    (TOKEN_SECRET)
  --client IP[,IP]      IPs/CIDRs allowed to reach the port (CLIENT_IP)

  --token TOKEN         the two above pre-assembled:        (PVE_TOKEN)
                        PVEAPIToken=user@realm!id=secret

  --port PORT           listen port, default 8000           (MCP_PORT)
  --api-key KEY         inbound bearer token, default: generated  (MCP_API_KEY)
  --no-firewall         skip the nftables allowlist
  -h, --help            this

Anything not supplied is prompted for, so a plain run asks three questions.
Re-running is safe: an existing token, bearer key or CA is left alone.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxmox-host) PROXMOX_HOST="$2"; shift 2 ;;
    --token)        PVE_TOKEN="$2"; shift 2 ;;
    --token-id)     TOKEN_ID="$2"; shift 2 ;;
    --secret)       TOKEN_SECRET="$2"; shift 2 ;;
    --client)       CLIENT_IP="$2"; shift 2 ;;
    --port)         MCP_PORT="$2"; shift 2 ;;
    --api-key)      MCP_API_KEY="$2"; shift 2 ;;
    --no-firewall)  WITH_FIREWALL=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; echo; usage >&2; exit 2 ;;
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
  wget -qO- <url>/install.sh | sudo bash -s -- \\
    --proxmox-host <ip> --token-id 'user@realm!tokenid' --secret <uuid> --client <ip>"
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

# The Proxmox GUI shows a token as two separate fields -- "Token ID" and
# "Secret" -- so ask for them the same way rather than making you paste them
# together into a header string you have never seen.
#
# --token still takes the assembled header form, for scripted installs.
trim() { local s="${1//$'\n'/}"; s="${s//$'\r'/}"; echo "${s#"${s%%[![:space:]]*}"}" | sed 's/[[:space:]]*$//'; }

if [[ -n "${PVE_TOKEN:-}" ]]; then
  PVE_TOKEN="$(trim "$PVE_TOKEN")"
  [[ "$PVE_TOKEN" == PVEAPIToken=* ]] \
    || die "--token must be the full header form: PVEAPIToken=user@realm!tokenid=secret
Or pass the two parts separately: --token-id 'user@realm!tokenid' --secret '<uuid>'"
  _body="${PVE_TOKEN#PVEAPIToken=}"
  TOKEN_ID="${_body%%=*}"
  TOKEN_SECRET="${_body#*=}"
else
  ask TOKEN_ID "Token ID     (e.g. svc-mcp@pam!mcpadmin)"
  TOKEN_ID="$(trim "$TOKEN_ID")"
  # Be forgiving about what gets pasted in: strip a header prefix, and if the
  # whole thing came in at once, split the secret back out rather than
  # rejecting it.
  TOKEN_ID="${TOKEN_ID#PVEAPIToken=}"
  if [[ "$TOKEN_ID" == *=* ]]; then
    TOKEN_SECRET="${TOKEN_ID#*=}"
    TOKEN_ID="${TOKEN_ID%%=*}"
  fi
  [[ -n "${TOKEN_SECRET:-}" ]] || ask TOKEN_SECRET "Token secret (the UUID shown once when you created it)"
fi

TOKEN_ID="$(trim "$TOKEN_ID")"
TOKEN_SECRET="$(trim "$TOKEN_SECRET")"

# user@realm!tokenid -- the realm matters and getting it wrong is an
# indistinguishable 401 later, so check the shape now.
[[ "$TOKEN_ID" == *@*!* ]] \
  || die "token ID should look like user@realm!tokenid (got: '$TOKEN_ID')
The Proxmox GUI shows it in the token list, e.g. svc-mcp@pam!mcpadmin"
[[ -n "$TOKEN_SECRET" ]] || die "the token secret is empty"

PVE_USER="${TOKEN_ID%%!*}"
PVE_TOKEN_NAME="${TOKEN_ID#*!}"
PVE_TOKEN_VALUE="$TOKEN_SECRET"
PVE_TOKEN="PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}"
note "token: ${TOKEN_ID}"

if [[ $WITH_FIREWALL -eq 1 ]]; then
  ask CLIENT_IP "IP allowed to reach the MCP port (your MCP client)"
  CLIENT_IP="$(trim "$CLIENT_IP")"
  # Accept a comma-separated list; validate each element so a typo fails here
  # rather than as an nftables syntax error three steps later.
  _norm=""
  IFS=',' read -ra _parts <<< "$CLIENT_IP"
  for _p in "${_parts[@]}"; do
    _p="$(trim "$_p")"
    [[ -z "$_p" ]] && continue
    [[ "$_p" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
      || die "'$_p' is not an IPv4 address or CIDR block"
    _norm="${_norm:+$_norm, }$_p"
  done
  [[ -n "$_norm" ]] || die "no valid client address given"
  CLIENT_IP="$_norm"

  # 0.0.0.0/0 is valid nftables and means "everyone" -- it turns the allowlist
  # into decoration. Accepted, because you may genuinely be firewalling
  # elsewhere, but not silently.
  if [[ "$CLIENT_IP" == *"0.0.0.0/0"* ]]; then
    printf '\n\033[33m    WARNING: 0.0.0.0/0 allows every host that can route here.\n'
    printf '    The bearer token becomes the only thing protecting Administrator\n'
    printf '    access to %s. Use --no-firewall if that is deliberate.\033[0m\n' "$PROXMOX_HOST"
  fi
  note "allowlist: $CLIENT_IP"
fi

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

say "Installing proxmox-mcp-plus $MCP_PLUS_VERSION"
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

# ------------------------------------------------------------------ Proxmox TLS

# Verify against the system trust store, which is all that is needed once the
# node has a real certificate (Let's Encrypt or otherwise). Only if that fails
# do we fall back to pinning Proxmox's own cluster CA -- a self-signed default
# install cannot be verified any other way, and the server refuses
# verify_ssl=false unless dev_mode is also on, which is a worse trade.
say "Proxmox TLS"

SYSTEM_CA="/etc/ssl/certs/ca-certificates.crt"
PVE_CA=""          # empty => use the system trust store

_ERRF="$(mktemp)"; trap 'rm -f "$_ERRF"' EXIT

probe_tls() {
  # $1 = --cacert argument, or "" for the system store.
  # Echoes the HTTP code; 000 means no response. A 401 still proves TLS is
  # fine, so the caller must not treat it as a TLS failure.
  local ca_args=()
  [[ -n "$1" ]] && ca_args=(--cacert "$1")
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    "${ca_args[@]}" -H "Authorization: $PVE_TOKEN" \
    "https://$PROXMOX_HOST:8006/api2/json/version" 2>"$_ERRF" || true
}

CODE="$(probe_tls "$SYSTEM_CA")"
CURL_ERR="$(tr -d '\r' < "$_ERRF" | grep -m1 '^curl:' || tr -d '\r' < "$_ERRF" | head -1)"

if [[ "$CODE" != "000" ]]; then
  note "verified against the system trust store -- no CA pinning needed"
  # A CA left behind by an older install would otherwise sit there unused and
  # confuse the next person to read the config.
  if [[ -e "$CONF_DIR/pve-ca.pem" ]]; then
    mv "$CONF_DIR/pve-ca.pem" "$CONF_DIR/pve-ca.pem.unused"
    note "moved the previously pinned CA aside (pve-ca.pem.unused)"
  fi
elif [[ "$CURL_ERR" == *"subject name"* || "$CURL_ERR" == *"not match"* ]]; then
  # The certificate is trusted -- it just is not for this name. Pinning cannot
  # fix that, so do not fall back. Say which names the cert actually carries
  # and stop. This is the normal outcome of dialling a node by IP once it has
  # a real certificate, because ACME issues for DNS names only.
  _peer="$(echo | openssl s_client -connect "$PROXMOX_HOST:8006" 2>/dev/null || true)"
  CERT_NAMES="$(printf '%s' "$_peer" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr -d ' ' | sed 's/DNS://g' || true)"
  CERT_SUBJ="$(printf '%s' "$_peer" | openssl x509 -noout -subject 2>/dev/null || true)"
  die "the certificate is trusted, but it is not valid for '$PROXMOX_HOST'.

  curl said:  ${CURL_ERR:-(no message)}
  ${CERT_SUBJ:-}
  valid for:  ${CERT_NAMES:-(could not read the SAN)}

Re-run using a name the certificate covers:

    --proxmox-host ${CERT_NAMES%%,*}

ACME issuers (Let's Encrypt and friends) sign DNS names only, never bare IPs,
so connecting by IP always fails this check once you move off the self-signed
default. Check this container can resolve that name."

else
  note "not verifiable against the system trust store: ${CURL_ERR:-(no message)}"

  # Reachable at all? If not, this is a network problem, not a TLS one.
  if [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Authorization: $PVE_TOKEN" \
        "https://$PROXMOX_HOST:8006/api2/json/version" 2>/dev/null || true)" == "000" ]]; then
    die "could not reach $PROXMOX_HOST:8006 at all.

  curl said: ${CURL_ERR:-(no message)}

Nothing answered, so this is not a credential or certificate problem. Check
that this container can route to the Proxmox host and that 8006 is open."
  fi

  note "falling back to pinning the Proxmox cluster CA (self-signed node)"

  if [[ ! -s "$CONF_DIR/pve-ca.pem" ]]; then
    # Check the status before parsing. Feeding an error page to a JSON parser
    # turns a plain 401 into "could not list nodes", which reads as a
    # permissions problem and sends you to entirely the wrong place.
    _nodes="$(curl -sk --max-time 20 -w '\n%{http_code}' \
      -H "Authorization: $PVE_TOKEN" \
      "https://$PROXMOX_HOST:8006/api2/json/nodes" 2>/dev/null)" || true
    _ncode="${_nodes##*$'\n'}"
    _nbody="${_nodes%$'\n'*}"
    case "$_ncode" in
      200) ;;
      401) die "Proxmox rejected the credential (401) while reading the node list.
Wrong realm (@pam vs @pve), a mistyped secret, or the token has been revoked.
The token ID you gave was: $TOKEN_ID" ;;
      *)   die "Proxmox returned $_ncode for /nodes; cannot continue." ;;
    esac
    NODE="$(printf '%s' "$_nbody" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
print(d[0]["node"] if d else "")' 2>/dev/null)" || true
    [[ -n "$NODE" ]] || die "the token authenticates but can see no nodes.
You almost certainly granted Administrator to the token but not to the user --
see README, 'the gotcha that catches everyone'."

    curl -sk --max-time 20 -H "Authorization: $PVE_TOKEN" \
      "https://$PROXMOX_HOST:8006/api2/json/nodes/$NODE/certificates/info" \
      | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
m=[c for c in d if c.get("filename")=="pve-root-ca.pem"]
sys.stdout.write(m[0]["pem"] if m else "")' > "$CONF_DIR/pve-ca.pem"

    [[ -s "$CONF_DIR/pve-ca.pem" ]] || die "could not retrieve the Proxmox cluster CA"
    chmod 0644 "$CONF_DIR/pve-ca.pem"
    note "node: $NODE"
    note "CA SHA256: $(openssl x509 -in "$CONF_DIR/pve-ca.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
    note "  verify on the host: openssl x509 -in /etc/pve/pve-root-ca.pem -noout -fingerprint -sha256"
  else
    note "reusing $CONF_DIR/pve-ca.pem"
  fi

  PVE_CA="$CONF_DIR/pve-ca.pem"

  # Prove the pinned CA actually validates before writing it into the config.
  CODE="$(probe_tls "$PVE_CA")"
  CURL_ERR="$(tr -d '\r' < "$_ERRF" | grep -m1 '^curl:' || tr -d '\r' < "$_ERRF" | head -1)"
  [[ "$CODE" != "000" ]] || die "the pinned CA does not validate $PROXMOX_HOST either.

  curl said: ${CURL_ERR:-(no message)}

Most often the address you gave is not in the certificate: PVE's default cert
carries the node name and its IP, so a DNS alias or unknown FQDN fails. Re-run
with the address that is in the cert, often the bare IP. If the node uses a
custom certificate the cluster CA did not issue, delete
$CONF_DIR/pve-ca.pem and install that issuer into the system trust store
instead."
fi

# --------------------------------------------------------- validate the token

# Do this before writing config: a token that authenticates but has no rights
# is the single most common way this ends up "installed but broken", and it
# reports success at every layer that only checks status codes.
say "Checking the token"


CODE="$(probe_tls "$PVE_CA")"
# curl writes a multi-line explanation for TLS failures; the first line is the
# one that names the actual problem ("curl: (60) SSL certificate problem:
# ..."). The remaining lines are boilerplate pointing at a web page, so taking
# the last line -- the obvious choice -- yields the least useful sentence.
CURL_ERR="$(tr -d '\r' < "$_ERRF" | grep -m1 '^curl:' || tr -d '\r' < "$_ERRF" | head -1)"

if [[ "$CODE" == "000" ]]; then
  # No HTTP response at all -- the request never completed, so this is a
  # transport problem and has nothing to do with the credential. Find out
  # which one by retrying without verification: if that works, the CA is at
  # fault; if it doesn't, we cannot reach the host.
  INSECURE_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: $PVE_TOKEN" \
    "https://$PROXMOX_HOST:8006/api2/json/version" 2>/dev/null)" || true

  if [[ "$INSECURE_CODE" != "000" ]]; then
    die "TLS verification against the pinned Proxmox CA failed.

  curl said: ${CURL_ERR:-(no message)}

The host IS reachable -- the same request without verification returned
$INSECURE_CODE -- so the credential and the network are fine. The CA at
$CONF_DIR/pve-ca.pem does not validate what $PROXMOX_HOST is presenting.

Usually one of:

  * You gave a hostname that is not in the certificate. PVE's default cert
    carries the node name and its IP; anything else (a DNS alias, a FQDN it
    does not know about) fails verification. Re-run with the address that is
    actually in the cert -- often the bare IP:
        --proxmox-host <ip>

  * The node uses an ACME/Let's Encrypt or custom certificate, so the
    cluster CA is not its issuer. In that case point at the system trust
    store instead: delete $CONF_DIR/pve-ca.pem, re-run, then set
    REQUESTS_CA_BUNDLE and SSL_CERT_FILE in
    $CONF_DIR/proxmox-mcp.env to /etc/ssl/certs/ca-certificates.crt

  * A stale CA from an earlier run, or the node regenerated its certs.
    Delete $CONF_DIR/pve-ca.pem and re-run to re-fetch it.

Inspect what is actually being presented with:
    openssl s_client -connect $PROXMOX_HOST:8006 -showcerts </dev/null"
  fi

  die "could not reach $PROXMOX_HOST:8006 at all.

  curl said: ${CURL_ERR:-(no message)}

Not a credential problem -- nothing answered. Check that the container can
route to the Proxmox host, that 8006 is open, and that the address is right."
fi

if [[ "$CODE" != "200" ]]; then
  case "$CODE" in
    401) die "Proxmox rejected the credential (401).
Wrong realm (@pam vs @pve), a mistyped secret, or a disabled account.
The token ID you gave was: $TOKEN_ID" ;;
    403) die "Proxmox returned 403 -- the credential is valid but not permitted
to read /version. That is unusual; check the account is not restricted." ;;
    *)   die "Proxmox returned $CODE for /version. ${CURL_ERR:-}" ;;
  esac
fi
note "authenticates (200), TLS verified against the pinned CA"

NODE_COUNT="$(curl -s --max-time 20 ${PVE_CA:+--cacert "$PVE_CA"} \
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

# TLS to Proxmox is verified, never disabled.
REQUESTS_CA_BUNDLE=${PVE_CA:-$SYSTEM_CA}
SSL_CERT_FILE=${PVE_CA:-$SYSTEM_CA}

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
