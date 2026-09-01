# LocalNode

A Flutter application that transforms your phone or computer into a secure, personal file server. Share and manage files on your local network (e.g., Wi-Fi, Tailscale) via a web browser, with easy access through a QR code and PIN authentication.

> **⚠️ Security Notice**: Versions prior to v1.6.0 contain known security vulnerabilities and are no longer supported. **Do not use v1.5.x or earlier.** Upgrade to v1.6.0 or later.

## Features

*   **Cross-Platform Server:** Turn your iOS, Android, Windows, macOS, or Linux device into a local HTTP/HTTPS file server.
*   **Web Browser Access:** Access and manage your files from any device with a web browser on the same network. No special client app required.
*   **Clipboard Sharing:** Sync text between devices via the clipboard sharing feature. Tag items with labels for easy identification.
*   **Secure File Sharing:** Upload, download, and manage files with PIN-based authentication.
*   **HTTPS/TLS Support:** Enable secure connections using your own TLS certificate and private key (e.g., from Tailscale). The SAN-aware selector automatically matches certificate entries to your device's IP addresses.
*   **Access Control:** Configure download-only mode or disable PIN authentication for trusted networks.
*   **Easy Connection:** Connect quickly using a QR code or by manually entering the displayed IP address.
*   **IP Address Selection:** Choose which network interface (e.g., Wi-Fi, Tailscale) to use for serving files. IPv4 only; IPv6 is not yet supported (#277).
*   **Custom Server Name:** Set a custom name displayed in the browser tab and page title.
*   **Custom Shared Folder:** Select any folder on your device as the shared directory.
*   **Settings Reset:** Reset all saved settings to defaults with a single button.
*   **CLI Mode:** Run as a headless server from the command line on desktop platforms with full option support.
*   **Client-only Web App:** The web version of LocalNode functions as a client to access servers running on other platforms.

## Download

### Mobile
*   **iOS:** [App Store](https://apps.apple.com/app/localnode/id6740804105)
*   **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.ictglab.localnode)

### Desktop
*   **macOS:** [Mac App Store](https://apps.apple.com/app/localnode/id6740804105)
*   **Windows / Linux (x64) / Linux (ARM64):** [GitHub Releases](https://github.com/koto2730/localnode/releases)

## Getting Started

### Build from Source

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/koto2730/localnode.git
    cd localnode/LocalNode
    ```
2.  **Get dependencies:**
    ```bash
    flutter pub get
    ```
3.  **Run the app:**
    ```bash
    flutter run
    ```

### GUI Mode

1.  **Start the Server:** Launch the app on your desired server device.
2.  **Select IP (Optional):** Choose the IP address to use if your device has multiple network interfaces.
3.  **Select Shared Folder (Optional):** Choose a custom folder to share, or use the default.
4.  **Scan QR or Enter Address:** Open a web browser on another device on the same network and either scan the QR code or manually enter the URL.
5.  **Authenticate:** Enter the PIN displayed in the app to access your files.
6.  **Manage Files:** Upload, download, and manage files directly from your web browser.

### CLI Mode

Run LocalNode as a headless server from the command line.

**Windows / Linux:**

Use the standalone `localnode-cli` binary included in the release archive:

```bash
# Windows
localnode-cli.exe [options]

# Linux
./localnode-cli [options]
```

**macOS:**

```bash
localnode --cli [options]
```

> **macOS (App Store):** The standalone `localnode` command is not available when installed from the Mac App Store. Use the binary inside the app bundle directly:
> ```bash
> /Applications/LocalNode.app/Contents/MacOS/LocalNode --cli [options]
> ```
> To simplify repeated use, add an alias to your shell config (`~/.zshrc`):
> ```bash
> alias localnode="/Applications/LocalNode.app/Contents/MacOS/LocalNode --cli"
> ```

**Options:**

| Option | Description |
|--------|-------------|
| `--config`, `-c` | Path to YAML config file (overridden by CLI args, see [examples/config.example.yaml](examples/config.example.yaml)) |
| `--state-file` | Path to persistent state file (device_id for federation). Default: `$XDG_STATE_HOME/localnode-cli/state.json` on POSIX, `%LOCALAPPDATA%\localnode-cli\state.json` on Windows |
| `--port`, `-p` | Server port (default: 8080) |
| `--ip` | IP address to advertise (skip auto-detection) |
| `--name`, `-n` | Custom server name (shown in browser tab/title) |
| `--pin` | Fixed PIN (random if not specified) |
| `--pin-length` | PIN length for random generation: 8..16 (default 8) |
| `--pin-charset` | PIN character set for random generation: `digits` (default), `alnum`, or `alnum_symbols` |
| `--dir`, `-d` | Shared directory path |
| `--cache-dir` | Base directory for cache/temp data (thumbnails, deployed web assets, zip staging). Default: the system temp directory (`$TMPDIR`/`$TEMP`/`/tmp`). Falls back to the system temp with a warning if the path is not writable. **macOS (`localnode --cli`):** the app is sandboxed, so paths outside its container are denied and it falls back to the system temp — use the standalone `localnode-cli` (Windows/Linux) if you need an arbitrary location |
| `--mode`, `-m` | Operation mode: `normal` or `download-only` |
| `--https-cert` | Path to TLS certificate file (cert.pem) |
| `--https-key` | Path to TLS private key file (key.pem) |
| `--advertise-host` | Hostname to show in the QR/URL, taken as-is from the certificate SAN, skipping DNS verification. For public-domain certs (e.g. via acme.sh) whose DNS does not resolve to the LAN IP by design. Requires `--ip` to also be set |
| `--post-action` | Script to execute on matching uploads: `pattern=script` (repeatable, glob pattern) |
| `--post-action-timeout` | Timeout in seconds for each post-action script; the process is killed if it exceeds this. `0` disables the timeout. Default: `300`. Prevents one hung script from blocking all later post-actions |
| `--accounts-file` | Path to a YAML passkey accounts file (WebAuthn login). Enables per-user passkey login alongside the PIN. Requires HTTPS + a hostname (or `localhost`) — see [Passkey login](#passkey-login-webauthn) |
| `--theme-css` | Path to a CSS file that customizes the Web UI appearance (colors / fonts / layout). Served same-origin as `/theme.css`, loaded after the built-in styles. Omit for the default look |
| `--theme-js` | Path to a JS file loaded into the Web UI (admin-only hook, served same-origin as `/theme.js`). Omit to inject nothing |
| `--mention-action` | Register clipboard mention command: `alias=script` (repeatable) |
| `--token` | Fixed Bearer token for upload and clipboard POST (random if not specified) |
| `--no-token` | Disable token-based authentication for upload and clipboard POST |
| `--no-pin` | Disable PIN authentication (upload token is also disabled in this mode) |
| `--no-clipboard` | Hide clipboard content from console output |
| `--verbose`, `-v` | Enable verbose request logging |
| `--help`, `-h` | Show help |

**Examples:**

```bash
# Start with defaults (port 8080, random PIN, current directory)
localnode-cli

# Specify port, PIN, and shared directory
localnode-cli -p 3000 --pin 12345678 -d /home/user/share

# Specify IP address (useful for WSL, VPN, multi-NIC)
localnode-cli -d /path/to/share --ip 192.168.1.100

# Set a custom server name
localnode-cli --name "My Server"

# Download-only mode without PIN
localnode-cli --mode download-only --no-pin

# Enable HTTPS with a Tailscale certificate
localnode-cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem

# Enable HTTPS with a public-domain certificate (e.g. from acme.sh) whose DNS
# does not point at the LAN IP (as it shouldn't) — skip DNS verification and
# advertise the cert's hostname explicitly
localnode-cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem \
  --advertise-host my-device.example.com --ip 192.168.1.100

# Run scripts based on uploaded file type
localnode-cli --post-action "*.png=./move-pic.sh" --post-action "*.zip=./unzip.sh"

# Run a script for all uploads
localnode-cli --post-action "*=./notify.sh"

# Trigger scripts via clipboard mention commands
localnode-cli --mention-action backup=./backup.sh --mention-action notify=./notify.sh

# Load options from a YAML config file (1.6.0+)
localnode-cli --config /etc/localnode/config.yaml

```

**Config file (YAML):** Long command lines can be replaced with a YAML config. See [examples/config.example.yaml](examples/config.example.yaml) for the full schema. CLI args always override config file values.

> **Note (`--post-action` / `--mention-action`):** The `script` value must be a path to an executable file only — passing arguments inline (e.g. `script=./notify.sh arg1`) is not supported. For `--post-action`, the uploaded file path is automatically passed as the first argument to the script.
>
> When several `--post-action` patterns match the same uploaded file (e.g. `*.png=./move.sh` and `*=./notify.sh`), the matching scripts run **sequentially in the order they were registered**, not in parallel. If an earlier script moves or deletes the file, later scripts receive the original (now-missing) path — order your actions accordingly.
>
> ```bash
> # Valid: executable path only; the uploaded file path is passed automatically
> localnode-cli --post-action "*.jpg=./process-image.sh"
>
> # Valid: mention action with an executable path only
> localnode-cli --mention-action backup=./backup.sh
> ```

To stop the server: **Ctrl+C**.

#### Upload with a clipboard notification (`POST /api/upload`)

A single upload request can also post a clipboard message, so an automation (e.g. a camera/watcher script) delivers a file and notifies viewers in one call. After the file is saved, these optional request headers append one clipboard item:

| Header | Description |
|--------|-------------|
| `x-clipboard-text` | Message body. Percent-encoded (like `x-filename`), so non-ASCII text is supported. |
| `x-clipboard-tag` | Optional tag/label for the clipboard item (like the web UI's sender name). Percent-encoded. |
| `x-clipboard-link` | If set to `1` and `x-clipboard-text` is absent, auto-composes the body as an `@file:<relpath>/<filename>` marker pointing at the just-saved file, so it renders as a thumbnail/chip. |

`x-clipboard-text` takes precedence over `x-clipboard-link`. Nothing is posted when neither is present, or when clipboard sharing is disabled (`--no-clipboard`).

> **Header encoding:** percent-encoding the text/tag is recommended (it is the only way HTTP headers can carry non-ASCII reliably). Raw UTF-8 bytes are also accepted and repaired server-side, so both forms display correctly.
>
> **Spaces in `@file:` / `@path:` markers:** a marker ends at the first whitespace, so a path containing spaces must be percent-encoded — e.g. `@file:my%20photo.jpg`. `x-clipboard-link` does this automatically (important because duplicate uploads are renamed to `name (1).ext`, which contains a space).

```bash
# Upload and notify in one request
curl -H "Authorization: Bearer <token>" \
     -H "x-filename: picture1.jpg" \
     -H "x-clipboard-text: motion%20detected" \
     -H "x-clipboard-tag: watcher-pi" \
     --data-binary @picture1.jpg \
     "http://host:8080/api/upload?path=triggers"

# Auto-compose an @file: chip for the uploaded file
curl -H "Authorization: Bearer <token>" \
     -H "x-filename: picture1.jpg" \
     -H "x-clipboard-link: 1" \
     --data-binary @picture1.jpg \
     "http://host:8080/api/upload?path=triggers"
```

#### State file (federation `device_id`)

For federation (parent/child pairing introduced in v1.6.0), the CLI persists a stable per-server identity to a small JSON state file. The path follows the XDG Base Directory specification on POSIX so it sits alongside other tools that already follow XDG (and gets picked up by backup tools that target XDG dirs):

- **Linux / macOS:** `$XDG_STATE_HOME/localnode-cli/state.json`, defaulting to `~/.local/state/localnode-cli/state.json` when `$XDG_STATE_HOME` is unset.
- **Windows:** `%LOCALAPPDATA%\localnode-cli\state.json`.

The file currently contains a single `device_id` UUID generated on first start. It is consulted (and re-created if missing) on every launch so peer identity stays stable across restarts. Override the location with `--state-file <path>` if you need to keep state alongside your config — for example, sharing config and state on a USB stick:

```bash
localnode-cli --config /mnt/usb/localnode.yaml --state-file /mnt/usb/state.json
```

> The state file path can also be set via `server.state-file` in the YAML config (the CLI arg overrides it).

#### Running as a service (systemd / launchd)

To run the CLI as a background service that starts on boot and restarts on failure, use the templates under [`examples/`](examples/):

> **Note:** `localnode-cli` reads its Web UI assets (`data/flutter_assets/…`) from disk next to the executable. Install the **whole extracted release directory** (e.g. to `/opt/localnode`) and run the binary from inside it — not just the single binary, or the server falls back to a minimal HTML page.

- **Linux (systemd):** [`examples/systemd/localnode.service`](examples/systemd/localnode.service) — a unit that runs `/opt/localnode/localnode-cli --config /etc/localnode/config.yaml` as a dedicated non-root user with filesystem hardening. The header comments list the exact install steps, or use the transparent helper:
  ```bash
  tar xzf localnode-linux-x64-v*.tar.gz -C /tmp/localnode-dist
  sudo examples/systemd/install-localnode.sh /tmp/localnode-dist
  # then edit /etc/localnode/config.yaml and:
  sudo systemctl enable --now localnode
  journalctl -u localnode -f
  ```
- **macOS (launchd):** [`examples/launchd/com.ictglab.localnode.plist`](examples/launchd/com.ictglab.localnode.plist) — a LaunchDaemon/LaunchAgent template. Use a self-built / non-App-Store `localnode-cli` binary: the Mac App Store build is sandboxed and cannot run reliably as a daemon writing to arbitrary paths.

Both point at `/etc/localnode/config.yaml` — see [`examples/config.example.yaml`](examples/config.example.yaml) for the full annotated config. Post-action / mention-action scripts run as the service user, so keep them minimal and trusted.

## Passkey login (WebAuthn)

Passkey login lets multiple people sign in with their own passkey instead of sharing one PIN — the SSH `authorized_keys` model applied to passkeys. It coexists with the PIN (the PIN stays available; a PIN session is an anonymous "guest").

**Requirement:** WebAuthn only works over a **secure context with a hostname** — an HTTPS origin (e.g. a Tailscale Funnel / cert hostname) or `http://localhost`. It does **not** work over a bare LAN IP (`http://192.168.x`). So passkey login targets public/HTTPS-hostname access; keep the PIN for plain-IP LAN use.

**Setup**

1. Start the server with an accounts file (created empty or non-existent is fine — you bootstrap the first account from the browser):
   ```bash
   localnode-cli --https-cert cert.pem --https-key key.pem \
                 --accounts-file /etc/localnode/accounts.yaml
   ```
   (or `server.accounts-file` in the YAML config)
2. Open the Web UI over the HTTPS hostname (or `https://localhost`), click **パスキーを登録 (register)** on the PIN screen, enter an account name, and create the passkey on your device.
3. The page shows a YAML snippet — paste it under `accounts:` in the accounts file and restart the server. See [`examples/accounts.example.yaml`](examples/accounts.example.yaml).
4. From then on, **🔑 パスキーでログイン** logs that account in.

Each account is one entry:
```yaml
accounts:
  - name: shiba
    credential_id: <base64url>   # shown by the register page
    public_key: <base64 SPKI>    # shown by the register page
```

**Attribution:** clipboard posts from a passkey session are auto-tagged with the account name (unless a tag is given), so the shared clipboard reads like a lightweight multi-person chat. Remove one line from the accounts file to revoke one person.

**Passkey-required mode (no PIN):** by default the PIN still works alongside passkeys. To drop the PIN entirely and require a passkey — recommended for public / Funnel exposure, where the 4–8 digit PIN is too weak — start with **both** `--no-pin` and `--accounts-file`:

```bash
localnode-cli --https-cert cert.pem --https-key key.pem \
              --no-pin --accounts-file /etc/localnode/accounts.yaml
```

In this mode the server is **not** open — a passkey login is required (`--no-pin` alone, without an accounts file, is still fully open as before). The upload Bearer token stays enabled (for curl/federation). The accounts file must already contain at least one account, or the server refuses to start (otherwise nobody could log in) — bootstrap by enrolling your first passkey in a normal PIN mode, then restart with `--no-pin`.

> Only ES256 (ECDSA P-256) passkeys are supported. Enrollment and login must be served from the same hostname.

## Federation (v1.6.0+)

Federation lets multiple CLI instances form a parent-child network so that clipboard entries and file uploads flow between nodes automatically.

**Requirements**: both sides must run over HTTPS with a fixed Bearer token (`--token`). `--no-pin` is not supported with federation.

### Configuration (YAML)

```yaml
server:
  token: "your-fixed-bearer-token"
  https-cert: /path/to/cert.pem
  https-key:  /path/to/key.pem

# Parent role — send events up to this node
parent:
  url:      https://parent-host:8080
  token:    "parent-issued-bearer-token"
  relation: friendly   # or: equally

# Child role — receive events from these nodes
children:
  - name:     child-pi
    url:      https://child-host:8080
    token:    "child-issued-bearer-token"
    relation: friendly
```

**Relations**

| Relation | Clipboard forwarding | File forwarding | `@run_to` result |
|----------|----------------------|-----------------|-----------------|
| `friendly` | Every item | Streams file to parent | Returned to parent |
| `equally` | `@up` items only | Notification post only | Not forwarded |

**Mention commands** (available when federation is configured)

| Command | Description |
|---------|-------------|
| `@up <text>` | Mark as important; forwarded even on `equally` links |
| `@list <child>` | Fetch the named child's mention list |
| `@to <child\|all> <message>` | Post a message to one or all children |
| `@run_to <child> <alias>` | Run a `@run` alias on the child; result returns to parent clipboard |

> **Note**: Mention commands typed into the clipboard (`@run`, `@run_to`, etc.) are executed only when the clipboard item is posted from an authenticated **browser session**. Clipboard posts authenticated via Bearer token (e.g. `curl`, or forwarded federation items) do **not** execute mentions.
>
> **Exception (federation `@run_to`)**: a parent invokes a child's `@run` alias through the dedicated `GET /api/run/<alias>` endpoint, which **is** reachable with the child's Bearer token by design. This means a leaked Bearer token can invoke any `@run` alias registered on that node (it cannot run arbitrary commands — only the pre-registered `--mention-action` scripts). Treat the token accordingly.

## Platform Support

| Platform | Server | CLI Mode | Distribution |
|----------|--------|----------|--------------|
| iOS | Yes | - | App Store |
| Android | Yes | - | Google Play |
| Windows | Yes | Yes | GitHub Releases |
| macOS | Yes | Yes | Mac App Store / GitHub Releases |
| Linux (x64) | Yes | Yes | GitHub Releases |
| Linux (ARM64) | Yes | Yes | GitHub Releases |
| Web | Client-only | - | - |

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
