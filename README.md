# proxmox-mcp-node

Runs the Proxmox VE API as an MCP server on its own container, listening on a
TCP port you point an MCP client at.

Streamable HTTP, bearer auth, TLS verified to Proxmox, nftables allowlist,
systemd. One script installs the lot.

## Install

On a fresh Debian 12/13 container:

```bash
wget -qO- https://raw.githubusercontent.com/rowanbsmith/proxmox-mcp-node/main/install.sh | sudo bash
```

`wget` is used rather than `curl` because it's the one that's actually there:
in Debian, `wget` and `ca-certificates` are priority *standard* and ship in a
base install, while `curl` is *optional* and a minimal container won't have it.
The installer pulls in `curl` (and `python3`, also not guaranteed) itself.

If your image does have curl:

```bash
curl -fsSL https://raw.githubusercontent.com/rowanbsmith/proxmox-mcp-node/main/install.sh | sudo bash
```

Neither? Three ways out, in order of least effort:

```bash
# 1. install one
apt-get update && apt-get install -y wget

# 2. push it in from the Proxmox host -- no networking in the container at all
pct push <vmid> install.sh /root/install.sh --perms 755
pct exec <vmid> -- /root/install.sh

# 3. python3, if that's what you have
python3 -c "import urllib.request;print(urllib.request.urlopen('https://raw.githubusercontent.com/rowanbsmith/proxmox-mcp-node/main/install.sh').read().decode())" > install.sh
sudo bash install.sh
```

It asks for three things:

| | |
|---|---|
| Proxmox host | IP or hostname of the PVE node |
| Proxmox API token | `PVEAPIToken=user@realm!id=secret` — see below |
| Client IP | the one host allowed to reach the MCP port |

and prints the endpoint URL and a generated bearer token when it's done.

### Unattended

Pass all three and it asks nothing:

```bash
wget -qO- <url>/install.sh | sudo bash -s -- \
  --proxmox-host 192.0.2.10 \
  --token 'PVEAPIToken=svc-mcp@pam!mcp-node=SECRET' \
  --client 192.0.2.20
```

Also: `--port` (default 8000), `--api-key` (default: generated),
`--no-firewall`.

Re-running is safe — it won't overwrite an existing token, bearer key or CA.

## Creating the Proxmox token

On the Proxmox host:

```bash
pveum acl modify / --users 'svc-mcp@pam' --roles Administrator
pveum user token add svc-mcp@pam mcp-node --privsep 1
pveum acl modify / --tokens 'svc-mcp@pam!mcp-node' --roles Administrator
```

The secret prints **once**. Paste it straight into the installer.

### The gotcha that catches everyone

A privilege-separated token gets **(the user's rights) ∩ (the token's rights)**.
Granting `Administrator` to the token alone gives you nothing — the
intersection with an unprivileged user is empty. You need *both* ACL lines
above.

Nothing warns you. The token authenticates fine and then sees an empty world:
Proxmox filters results rather than refusing, so `/nodes` returns `200` with an
empty list. Anything that checks status codes reports it as working.

The installer checks for this explicitly and refuses to finish if the token
can't see any nodes.

Also: `@pam`, not `@pve`. Wrong realm is an indistinguishable `401`.

## Using it

```
http://<node>:8000/mcp
Authorization: Bearer <token printed by the installer>
```

Any MCP client that speaks Streamable HTTP. Nothing about the client is this
repo's problem.

## Operating it

```bash
systemctl status proxmox-mcp
journalctl -u proxmox-mcp -f

# allowlist -- reload, don't restart: `nft -f` merges, so a removed client
# would otherwise stay allowed
nano /etc/proxmox-mcp/firewall.nft
systemctl reload proxmox-mcp-firewall
nft list table inet proxmox_mcp
```

| Path | |
|---|---|
| `/etc/proxmox-mcp/proxmox-mcp.env` | config **and secrets**, 0640 |
| `/etc/proxmox-mcp/firewall.nft` | client allowlist |
| `/etc/proxmox-mcp/pve-ca.pem` | pinned Proxmox CA |
| `/opt/proxmox-mcp/.venv` | the Python environment |
| `/var/lib/proxmox-mcp/` | job state |

To restrict what the server can do at all, set `MCP_TOOL_DENYLIST` (or
`MCP_TOOL_ALLOWLIST`) in the env file and restart. A tool named there isn't
registered and can't be called by any client, whatever token it holds.

### Uninstall

```bash
systemctl disable --now proxmox-mcp proxmox-mcp-firewall
rm -f /etc/systemd/system/proxmox-mcp{,-firewall}.service
systemctl daemon-reload
nft delete table inet proxmox_mcp 2>/dev/null
rm -rf /opt/proxmox-mcp /var/lib/proxmox-mcp /etc/proxmox-mcp
userdel proxmox-mcp
# and revoke the token -- deleting the file revokes nothing:
#   pveum user token remove svc-mcp@pam mcp-node
```

## What you're accepting

- **The bearer token is Administrator on your Proxmox host.** There's no
  permission layer narrowing it and no confirmation step — this is a daemon.
  If your client is an LLM, the approve-before-mutating gate belongs there.
- **Plain HTTP.** The token crosses the network in cleartext on every request.
  The allowlist and the LAN are the trust boundary. Don't port-forward it. For
  TLS, tunnel it (WireGuard/SSH, with `MCP_HOST=127.0.0.1`) or put a
  TLS-terminating proxy in front — if you do the latter, disable response
  buffering, since the responses are SSE.
- **Tool arguments are logged** to the journal. That's the audit trail.

## Upstream

[`RekklesNA/ProxmoxMCP-Plus`](https://github.com/RekklesNA/ProxmoxMCP-Plus)
(MIT), installed from PyPI at **v0.5.18**, with all 54 dependencies pinned
inside `install.sh` and installed `--no-deps` so nothing re-resolves.

Don't go below v0.5.17: [GHSA-88xv-43vf-jm73](https://github.com/RekklesNA/ProxmoxMCP-Plus/security/advisories)
is that HTTP mode didn't enforce an API key — an advisory about exactly the
mode this runs in.

To upgrade, bump the pins in `install.sh` and re-run it.
