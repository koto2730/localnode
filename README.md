# LocalNode

A Flutter application that transforms your phone or computer into a secure, personal file server. Share and manage files on your local network (e.g., Wi-Fi, Tailscale) via a web browser, with easy access through a QR code and PIN authentication.

## Features

*   **Cross-Platform Server:** Turn your iOS, Android, Windows, macOS, or Linux device into a local HTTP file server.
*   **Web Browser Access:** Access and manage your files from any device with a web browser on the same network. No special client app required.
*   **HTTPS Support:** Serve over HTTPS by providing your own certificate files (e.g., from Tailscale or Let's Encrypt). Hostname-aware QR code generation included.
*   **Clipboard Sharing:** Sync text between devices via the clipboard sharing feature. Tag items with labels for easy identification.
*   **Secure File Sharing:** Upload, download, and manage files with PIN-based authentication.
*   **Access Control:** Configure download-only mode or disable PIN authentication for trusted networks.
*   **Easy Connection:** Connect quickly using a QR code or by manually entering the displayed IP address.
*   **IP Address Selection:** Choose which network interface (e.g., Wi-Fi, Tailscale) to use for serving files.
*   **Custom Server Name:** Set a custom name displayed in the browser tab and page title.
*   **Custom Shared Folder:** Select any folder on your device as the shared directory.
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

Run LocalNode as a headless server from the command line (Windows, macOS, Linux):

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
| `--port`, `-p` | Server port (default: 8080) |
| `--ip` | IP address to advertise (skip auto-detection) |
| `--name`, `-n` | Custom server name (shown in browser tab/title) |
| `--pin` | Fixed PIN (random if not specified) |
| `--dir`, `-d` | Shared directory path |
| `--mode`, `-m` | Operation mode: `normal` or `download-only` |
| `--no-pin` | Disable PIN authentication |
| `--no-clipboard` | Hide clipboard content from console output |
| `--https-cert` | Path to TLS certificate file (PEM). Enables HTTPS when set with `--https-key` |
| `--https-key` | Path to TLS private key file (PEM). Enables HTTPS when set with `--https-cert` |
| `--https-port` | HTTPS server port (default: 8443) |
| `--verbose`, `-v` | Enable verbose request logging |
| `--help`, `-h` | Show help |

**Examples:**

```bash
# Start with defaults (port 8080, random PIN, current directory)
localnode --cli

# Specify port, PIN, and shared directory
localnode --cli -p 3000 --pin 1234 -d /home/user/share

# Specify IP address (useful for WSL, VPN, multi-NIC)
localnode --cli -d /path/to/share --ip 192.168.1.100

# Set a custom server name
localnode --cli --name "My Server"

# Download-only mode without PIN
localnode --cli --mode download-only --no-pin

# Start with HTTPS using your own certificate (e.g., from Tailscale)
localnode --cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem
```

To stop the server: **Ctrl+C**.

> **Note (Windows):** On Windows, only Ctrl+C is supported to stop the server.

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

## HTTPS Setup

LocalNode supports HTTPS when you provide your own certificate and private key files.

### Getting a Certificate

**Tailscale (recommended for Tailscale users)**

```bash
tailscale cert <your-device-hostname>
# Generates: <hostname>.crt and <hostname>.key
```

Then in LocalNode GUI, set the cert and key paths and set the hostname to your Tailscale hostname (e.g., `mydevice.tailnet.ts.net`). The QR code will use that hostname so clients connect via the valid cert.

**Let's Encrypt (if you have a domain)**

```bash
certbot certonly --standalone -d yourdomain.example.com
# Cert: /etc/letsencrypt/live/yourdomain.example.com/fullchain.pem
# Key:  /etc/letsencrypt/live/yourdomain.example.com/privkey.pem
```

**Self-signed (local testing only)**

```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
```

> Note: Self-signed certificates will show a browser warning unless you manually install the CA on each client device.

### GUI Setup

1. In the server settings, set the paths to your `cert.pem` and `key.pem` files.
2. (Optional) Set the hostname field to match your certificate's domain — the QR code and URL will use this hostname instead of the IP address.
3. Start the server. It will serve over HTTPS on the configured port (default: 8443).

### CLI Setup

```bash
localnode --cli --https-cert cert.pem --https-key key.pem
localnode-cli --https-cert cert.pem --https-key key.pem --https-port 443
```

Both `--https-cert` and `--https-key` must be specified together.

---

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
