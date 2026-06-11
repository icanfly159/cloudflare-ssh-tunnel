# Cloudflare SSH Tunnel — one-script setup

Expose a VM's SSH over a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) with a single interactive script. No open inbound ports, no public IP needed.

Two access modes:

| Mode | What it means | Client needs |
|------|---------------|--------------|
| **Browser** | Log in to a terminal from any web browser via Cloudflare Access | Nothing — just a browser |
| **Terminal** | Classic `ssh` client, tunneled through Cloudflare | `cloudflared` + 2 lines of SSH config |

## Quick start (on the VM / server)

```bash
git clone <this-repo>
cd claudeflare-tunnel
chmod +x setup.sh
./setup.sh
```

The script walks you through 5 steps, asking **one question at a time**:

1. **Access mode** — browser or terminal, and native systemd vs Docker
2. **Prerequisites** — auto-installs `curl`, `jq`, `openssh-server`, `cloudflared` (or Docker)
3. **Credentials** — asks one value per prompt: API token → Account ID → Zone ID → hostname → tunnel name
4. **Automatic build** — creates the tunnel, DNS record, ingress config, optional Access app + policy, and starts cloudflared. No input needed.
5. **Client-side checklist** — prints exactly what's left to do on your client machine, depending on the mode you chose in step 1

Safe to re-run: existing tunnels, DNS records, and Access apps are reused, not duplicated.

## What you need before running

A Cloudflare account with your domain on it, and an **API token** ([create one here](https://dash.cloudflare.com/profile/api-tokens)) with:

- Account → **Cloudflare Tunnel : Edit**
- Zone → **DNS : Edit**
- Account → **Access: Apps and Policies : Edit** (only if using browser mode / Access policy)

You'll also need your **Account ID** and **Zone ID** (shown on your domain's overview page in the Cloudflare dashboard).

## Security

- Everything you enter is saved to **`tunnel.env`** (`chmod 600`) so re-runs don't re-ask. This file is **gitignored — never commit it**.
- The API token prompt hides your input.
- No secrets are ever written into tracked files.

## Files

```
setup.sh     ← the script, run this
README.md    ← you are here
Command.md   ← manual step-by-step reference (what the script automates)
tunnel.env   ← created at runtime, holds YOUR secrets, gitignored
```
