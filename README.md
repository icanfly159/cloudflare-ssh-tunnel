# Cloudflare SSH Tunnel — one-script setup

Reach your VM over SSH through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — **no open ports, no public IP, no router config.**

I built this so you don't have to do the whole Cloudflare Tunnel setup by hand every time. Run **one script** on the server, answer a few questions, and you're done. Re-running is safe — it reuses what already exists instead of making duplicates.

There are two ways to log in:

| Mode | How you connect | What the client needs |
|------|-----------------|------------------------|
| **Browser** | Open your hostname in any web browser, log in with a One-Time PIN | Nothing — just a browser |
| **Terminal** | Classic `ssh user@host` from your terminal | `cloudflared` + a few lines of SSH config (explained below) |

> Browser mode can **also** give you terminal access — but only if you add the client config in the Terminal section. Terminal-only mode skips the browser login.

---

## 📺 Watch first (optional)

> _Video walkthrough goes here — drop the link/embed below._
>
> `<!-- VIDEO: paste your video link here -->`

---

## 1. Before you run — get these ready

You need a Cloudflare account with **your domain already added to it**, plus an **API token**.

**Create the API token** here → https://dash.cloudflare.com/profile/api-tokens
Give it these permissions:

- Account → **Cloudflare Tunnel : Edit**
- Zone → **DNS : Edit**
- Account → **Access: Apps and Policies : Edit** *(only if you use Browser mode / login)*
- Account → **Access: Organizations, Identity Providers, and Groups : Read** *(only if you use Browser mode / login)*

Also grab these two IDs from your domain's **Overview** page in the Cloudflare dashboard:

- **Account ID**
- **Zone ID**

And pick the **hostname** you want to use, e.g. `ssh.example.com` (it must be a subdomain of your Cloudflare domain). The script creates the DNS record for it automatically.

> 💡 In Cloudflare Zero Trust, make sure **One-Time PIN** login is enabled (Settings → Authentication). It's on by default.

---

## 2. Quick start (run this on the VM / server)

```bash
git clone https://github.com/icanfly159/cloudflare-ssh-tunnel.git
cd cloudflare-ssh-tunnel && chmod +x setup.sh && ./setup.sh
```

The script asks **one question at a time** and does the rest:

1. **Access mode** — Browser or Terminal
2. **Prerequisites** — installs `curl`, `jq`, `openssh-server`, `cloudflared` if missing
3. **Credentials** — API token → Account ID → Zone ID → hostname → tunnel name
4. **Build** — creates the tunnel, DNS record, login policy (Browser mode), and starts `cloudflared`
5. **Client checklist** — prints exactly what's left to do, based on the mode you picked

When it finishes, the tunnel runs as a background service (`systemctl status cloudflared`).

---

## 3. Client-side setup (this is the important part)

**This depends on which mode you chose.** Don't just copy-paste blindly — anywhere you see `ssh.example.com`, **replace it with the hostname you actually chose.**

<details open>
<summary><b>🌐 Browser mode — nothing to install</b></summary>

1. Open **`https://ssh.example.com`** in any browser. ⬅️ *use your hostname*
2. Log in with one of the allowed emails (Cloudflare emails you a 6-digit PIN).
3. A terminal opens in the browser — type your VM username and your key/password.

That's it. No client install needed.
</details>

<details>
<summary><b>💻 Terminal access (Terminal mode, OR Browser mode + want <code>ssh</code> too)</b></summary>

Do this **on every client machine** you want to connect from:

**a. Install `cloudflared` on the client**
- macOS: `brew install cloudflared`
- Linux/Windows: https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/download-warp/

**b. Add this block to the client's `~/.ssh/config`** — ⬅️ **change `ssh.example.com` to your hostname (3 places):**

```ssh
Host ssh.example.com
  ProxyCommand cloudflared access ssh --hostname %h
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking accept-new
```

> The last two lines stop the *"REMOTE HOST IDENTIFICATION HAS CHANGED"* error if the VM is ever rebuilt. They apply **only to this host** — all your other SSH connections keep normal strict checking.

**c. Connect:**

```bash
ssh <your-user>@ssh.example.com
```

The first connection opens a browser to log in (Browser mode / when a login policy is on). After that it just works.
</details>

---

## 4. Set up an SSH key (recommended — one command each)

Passwords work, but a key is safer and skips typing a password every time.

**On the CLIENT — generate a key (one command):**

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/id_ed25519 -N ""
```

**Copy the key to the SERVER (one command).** Easiest, once your `~/.ssh/config` from step 3 is in place:

```bash
ssh-copy-id <your-user>@ssh.example.com
```

> No `ssh-copy-id` (e.g. on Windows)? Run this **on the server** instead — paste your public key in place of the example text:
> ```bash
> echo "ssh-ed25519 AAAA...your-public-key... you@host" >> ~/.ssh/authorized_keys
> ```
> (Your public key is the contents of `~/.ssh/id_ed25519.pub` on the client.)

Now `ssh <your-user>@ssh.example.com` logs you in with no password.

---

## 5. Multiple servers / multiple people

- **Re-running on the same server** is safe — the existing tunnel, DNS record, and login policy are reused, not duplicated.
- **Setting up another VM with a different list of allowed emails?** The script checks your existing login policies by their *email list*. If the emails match, it reuses that policy; if they're different, it makes a new one (`one-time-pin`, `one-time-pin(1)`, …) so your other VM's policy is never overwritten.
- In **Browser mode** you add allowed emails one at a time — after each one it asks *"Add another email that can log in?"* Answer `n` when you're done.

---

## 6. Troubleshooting

| Problem | Fix |
|---------|-----|
| `cloudflared: command not found` on the client | You skipped step 3a — install `cloudflared` on the **client**, not just the server. |
| `ssh` hangs or "connection refused" | Check the tunnel is up on the server: `systemctl status cloudflared`. |
| Browser login never asks for a PIN | Enable **One-Time PIN** in Zero Trust → Settings → Authentication, then re-run. |
| "REMOTE HOST IDENTIFICATION HAS CHANGED" | You're missing the last two lines of the `~/.ssh/config` block in step 3b. |
| API token / permission errors when running the script | Re-check the token permissions in section 1 — the script tells you exactly which one is missing. |

---

## Security notes

- Everything you type is saved to **`tunnel.env`** (`chmod 600`) so re-runs don't re-ask. It's **gitignored — never commit it.**
- The API-token prompt hides your input.
- No secrets are ever written into tracked files.
- Browser mode requires a login (One-Time PIN) before SSH is reachable. Terminal-only mode does **not** add a login by design — anyone who can reach the tunnel can reach the SSH port, so use it only when you trust that.

---

## Files

```
setup.sh     ← the script — run this on the server
README.md    ← you are here
tunnel.env   ← created at runtime, holds YOUR secrets, gitignored
```
