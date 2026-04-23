# LocalNode

A Flutter application that transforms your phone or computer into a secure, personal file server. Share and manage files on your local network (e.g., Wi-Fi, Tailscale) via a web browser, with easy access through a QR code and PIN authentication.

## Features

*   **Cross-Platform Server:** Turn your iOS, Android, Windows, macOS, or Linux device into a local HTTP/HTTPS file server.
*   **Web Browser Access:** Access and manage your files from any device with a web browser on the same network. No special client app required.
*   **Clipboard Sharing:** Sync text between devices via the clipboard sharing feature. Tag items with labels for easy identification.
*   **Secure File Sharing:** Upload, download, and manage files with PIN-based authentication.
*   **HTTPS/TLS Support:** Enable secure connections using your own TLS certificate and private key (e.g., from Tailscale). The SAN-aware selector automatically matches certificate entries to your device's IP addresses.
*   **Access Control:** Configure download-only mode or disable PIN authentication for trusted networks.
*   **Easy Connection:** Connect quickly using a QR code or by manually entering the displayed IP address.
*   **IP Address Selection:** Choose which network interface (e.g., Wi-Fi, Tailscale) to use for serving files.
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
| `--port`, `-p` | Server port (default: 8080) |
| `--ip` | IP address to advertise (skip auto-detection) |
| `--name`, `-n` | Custom server name (shown in browser tab/title) |
| `--pin` | Fixed PIN (random if not specified) |
| `--dir`, `-d` | Shared directory path |
| `--mode`, `-m` | Operation mode: `normal` or `download-only` |
| `--https-cert` | Path to TLS certificate file (cert.pem) |
| `--https-key` | Path to TLS private key file (key.pem) |
| `--post-action` | Script to execute on matching uploads: `pattern=script` (repeatable, glob pattern) |
| `--mention-action` | Register clipboard mention command: `alias=script` (repeatable) |
| `--token` | Fixed upload token for Bearer auth (random if not specified) |
| `--no-token` | Disable token-based upload authentication |
| `--no-pin` | Disable PIN authentication |
| `--no-clipboard` | Hide clipboard content from console output |
| `--verbose`, `-v` | Enable verbose request logging |
| `--help`, `-h` | Show help |

**Examples:**

```bash
# Start with defaults (port 8080, random PIN, current directory)
localnode-cli

# Specify port, PIN, and shared directory
localnode-cli -p 3000 --pin 1234 -d /home/user/share

# Specify IP address (useful for WSL, VPN, multi-NIC)
localnode-cli -d /path/to/share --ip 192.168.1.100

# Set a custom server name
localnode-cli --name "My Server"

# Download-only mode without PIN
localnode-cli --mode download-only --no-pin

# Enable HTTPS with a Tailscale certificate
localnode-cli --https-cert /path/to/cert.pem --https-key /path/to/key.pem

# Run scripts based on uploaded file type
localnode-cli --post-action "*.png=./move-pic.sh" --post-action "*.zip=./unzip.sh"

# Run a script for all uploads
localnode-cli --post-action "*=./notify.sh"

# Trigger scripts via clipboard mention commands
localnode-cli --mention-action backup=./backup.sh --mention-action notify=./notify.sh

```

> **Note (`--post-action` / `--mention-action`):** The `script` value must be a path to an executable file only — passing arguments inline (e.g. `script=./notify.sh arg1`) is not supported. For `--post-action`, the uploaded file path is automatically passed as the first argument to the script.
>
> ```bash
> # Valid: executable path only; the uploaded file path is passed automatically
> localnode-cli --post-action "*.jpg=./process-image.sh"
>
> # Valid: mention action with an executable path only
> localnode-cli --mention-action backup=./backup.sh
> ```

To stop the server: **Ctrl+C**.

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
