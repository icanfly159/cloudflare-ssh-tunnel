# Cloudflare SSH Tunnel — one-script setup

Reach your VM over SSH through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — **no open ports, no public IP, no router config.** Run one script on the server, answer a few questions, done. Safe to re-run.

---

## Quick start (run this on the VM / server)

```bash
git clone https://github.com/icanfly159/cloudflare-ssh-tunnel.git
cd cloudflare-ssh-tunnel && chmod +x setup.sh && ./setup.sh
```

The very first question the script asks is **which mode you want**. Pick one and jump to its guide:

### 👉 Choose your mode

| Mode | Pick this if… | Go to |
|------|----------------|-------|
| **Browser** | You want to log in from a web browser (with a One-Time PIN). Most secure. | [▶ Browser setup](#-browser-setup) |
| **Terminal** | You only want classic `ssh user@host` from your terminal. | [▶ Terminal setup](#-terminal-setup) |

> Browser mode can **also** be used from the terminal later — see [Client-side setup](#client-side-setup).

---

## ▶ Browser setup

Browser mode needs the **most permissions** because it creates a login (Access) policy.

### Step 1 — Create the API token

Go to https://dash.cloudflare.com/profile/api-tokens → **Create Token** → **Create Custom Token**, and add **all four** permissions:

- Account → **Cloudflare Tunnel : Edit**
- Zone → **DNS : Edit**
- Account → **Access: Apps and Policies : Edit**
- Account → **Access: Organizations, Identity Providers, and Groups : Read**

### Step 2 — Find your Account ID and Zone ID

Open your domain in the [Cloudflare dashboard](https://dash.cloudflare.com). On the domain's **Overview** page (right-hand side / "API" box) you'll see:

- **Account ID**
- **Zone ID**

Both are 32-character codes. You paste them into the script when asked.

### Step 3 — Run the script

It asks, one at a time: **API token → Account ID → Zone ID → hostname → tunnel name**, then the **emails** allowed to log in (add them one at a time; answer `n` to "add another?" when done). It then builds the tunnel, DNS record, and login policy.

### Step 4 — Log in

1. Open **`https://<your-hostname>`** in any browser.
2. Enter an allowed email → Cloudflare emails you a 6-digit PIN.
3. A terminal opens in the browser — type your VM username and key/password.

Want `ssh` from the terminal too? → [Client-side setup](#client-side-setup).

---

## ▶ Terminal setup

Terminal mode is simpler and needs **fewer permissions** (no login policy).

### Step 1 — Create the API token

Go to https://dash.cloudflare.com/profile/api-tokens → **Create Custom Token**, and add just **two** permissions:

- Account → **Cloudflare Tunnel : Edit**
- Zone → **DNS : Edit**

You'll also need your **Account ID** and **Zone ID** (domain **Overview** page in the dashboard).

### Step 2 — Run the script

Choose **Terminal** at the first question. It asks: **API token → Account ID → Zone ID → hostname → tunnel name**, then builds the tunnel and DNS record. No login is added — anyone who can reach the tunnel can reach SSH, so use this only on trusted setups.

### Step 3 — Finish on the client

Terminal mode **only works after you configure the client** → [Client-side setup](#client-side-setup).

---

## Client-side setup

Needed for **Terminal mode**, and for **Browser mode if you also want `ssh user@host`**.
Do this **on each client machine**. Anywhere you see `ssh.example.com`, **replace it with your own hostname.**

**1. Install `cloudflared` on the client**
- macOS: `brew install cloudflared`
- Linux / Windows: https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/download-warp/

**2. Add this to the client's `~/.ssh/config`** — ⬅️ change `ssh.example.com` (3 places):

```ssh
Host ssh.example.com
  ProxyCommand cloudflared access ssh --hostname %h
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking accept-new
```

**3. (Recommended) Set up an SSH key — one command each**

On the **client**, generate a key:
```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/id_ed25519 -N ""
```
Copy it to the **server**:
```bash
ssh-copy-id <your-user>@ssh.example.com
```

**4. Connect**
```bash
ssh <your-user>@ssh.example.com
```
In Browser mode, the first connection opens a browser to log in; after that it just works.

---

## Notes

- Everything you enter is saved to **`tunnel.env`** (`chmod 600`, gitignored) so re-runs don't re-ask — **never commit it.**
- Re-running is safe: existing tunnel, DNS record, and login policy are reused, not duplicated.
- Different VM with different allowed emails? The script makes a separate login policy (`one-time-pin(1)`, …) instead of overwriting the old one.

```
setup.sh     ← the script — run this on the server
README.md    ← you are here
tunnel.env   ← created at runtime, holds YOUR secrets, gitignored
```
