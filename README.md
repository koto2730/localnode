# LocalNode

A Flutter application that transforms your phone or computer into a secure, personal file server. Share and manage files on your local network (e.g., Wi-Fi, Tailscale) via a web browser, with easy access through a QR code and PIN authentication.

## Features

*   **Cross-Platform Server:** Turn your iOS, Android, Windows, macOS, or Linux device into a local HTTP file server.
*   **Web Browser Access:** Access and manage your files from any device with a web browser on the same network. No special client app required.
*   **Clipboard Sharing:** Sync text between devices via the clipboard sharing feature.
*   **Secure File Sharing:** Upload, download, and manage files with PIN-based authentication.
*   **Access Control:** Configure download-only mode or disable PIN authentication for trusted networks.
*   **Easy Connection:** Connect quickly using a QR code or by manually entering the displayed IP address.
*   **IP Address Selection:** Choose which network interface (e.g., Wi-Fi, Tailscale) to use for serving files.
*   **Custom Shared Folder:** Select any folder on your device as the shared directory.
*   **CLI Mode:** Run as a headless server from the command line on desktop platforms.
*   **Client-only Web App:** The web version of LocalNode functions as a client to access servers running on other platforms.

## Download

### Mobile
*   **iOS:** [App Store](https://apps.apple.com/app/localnode/id6740804105)
*   **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.ictglab.localnode)

### Desktop
Windows, Linux builds are available on [GitHub Releases](https://github.com/koto2730/localnode/releases).

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

**Options:**

| Option | Description |
|--------|-------------|
| `--port`, `-p` | Server port (default: 8080) |
| `--pin` | Fixed PIN (random if not specified) |
| `--dir`, `-d` | Shared directory path |
| `--mode`, `-m` | Operation mode: `normal` or `download-only` |
| `--no-pin` | Disable PIN authentication |
| `--help`, `-h` | Show help |

**Examples:**

```bash
localnode --cli --port 8080 --pin 1234 --dir /home/user/share
localnode --cli --mode download-only --no-pin --dir /home/user/share
```

## Platform Support

| Platform | Server | CLI Mode |
|----------|--------|----------|
| iOS | Yes | - |
| Android | Yes | - |
| Windows | Yes | Yes |
| macOS | Yes | Yes |
| Linux | Yes (x64) | Yes |
| Web | Client-only | - |

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
