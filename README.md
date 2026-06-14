# Cloudflare SSH Tunnel — one-script setup

Reach your VM over SSH through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — **no open ports, no public IP, no router config.** Run one script on the server, answer a few questions, done. Safe to re-run.

---

## Quick start (run this on the VM / server)

```bash
git clone https://github.com/icanfly159/cloudflare-ssh-tunnel.git
cd cloudflare-ssh-tunnel && chmod +x setup.sh && ./setup.sh
```

---

## Set up your SSH key first (recommended)

A key is safer than a password and saves you typing one every time. Do this **on the client machine** you'll connect from (the computer you SSH *from*). Pick your operating system — each is **one command:**



**🍏 macOS & 🐧 Linux**
```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/id_ed25519 -N ""
```

**🪟 Windows (PowerShell)**
```powershell
ssh-keygen -t ed25519 -C "$env:USERNAME@$env:COMPUTERNAME" -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""'
```

This creates two files — a **private** key (keep secret, never share) and a **public** key (this is what goes on the server):

| | Private key | Public key |
|---|---|---|
| Linux / macOS | `~/.ssh/id_ed25519` | `~/.ssh/id_ed25519.pub` |
| Windows | `%USERPROFILE%\.ssh\id_ed25519` | `%USERPROFILE%\.ssh\id_ed25519.pub` |

Show your **public** key so you can copy its text (you'll paste it onto the VM in [Client-side setup](#client-side-setup)):

- Linux / macOS: `cat ~/.ssh/id_ed25519.pub`
- Windows: `type %USERPROFILE%\.ssh\id_ed25519.pub`

---

## Choose your mode

The very first question the script asks is **which mode you want**. Pick one and jump to its guide:

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

<img width="1280" height="720" alt="Image" src="https://github.com/user-attachments/assets/167aad6a-21e0-43c3-b61e-cd8a5c2f0933" />

### Step 2 — Find your Account ID and Zone ID

Open your domain in the [Cloudflare dashboard](https://dash.cloudflare.com). On the domain's **Overview** page (right-hand side / "API" box) you'll see:

- **Account ID**
- **Zone ID**

Both are 32-character codes. You paste them into the script when asked.

<img width="1280" height="720" alt="Image" src="https://github.com/user-attachments/assets/83fc6db2-3932-46f4-93dc-3cf6c0960d2b" />

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

> Jump to [Find your Account ID and Zone ID](#step-2--find-your-account-id-and-zone-id), which shows where the Account ID and Zone ID are.

<img width="1280" height="720" alt="Image" src="https://github.com/user-attachments/assets/4b8a2627-b1d2-4ef7-aa2c-4fa308143d99" />

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

> ⚠️ **Heads up:** the last two lines turn **off SSH host-key checking** for this host — no host key is saved or compared, so SSH will **not** warn you if the server's identity ever changes. This is intentional for tunnelled SSH (Cloudflare is the trust layer), but if you'd rather verify host keys the normal way, delete those two lines.

**3. Add your public key to the server — run this ON the VM**

Copy the **public** key text you printed earlier in [Set up your SSH key first](#set-up-your-ssh-key-first-recommended), then run this **on the VM/server** (paste your key in place of the example), as the user you'll log in as:

```bash
mkdir -p ~/.ssh && echo "ssh-ed25519 AAAA...your-public-key... you@host" >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

> One command: it creates `~/.ssh` if missing, appends your key, and fixes the permissions SSH requires.

**4. Connect**
```bash
ssh <your-user>@ssh.example.com
```
In Browser mode, the first connection opens a browser to log in; after that it just works.




