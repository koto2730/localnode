# LocalNode

A Flutter application that transforms your phone or computer into a secure, personal file server. Share and manage files on your local network (e.g., Wi-Fi, Tailscale) via a web browser, with easy access through a QR code and PIN authentication.

## ✨ Features

*   **Cross-Platform Server:** Turn your iOS, Android, Windows, macOS, or Linux device into a local HTTP file server.
*   **Web Browser Access:** Access and manage your files from any device with a web browser on the same network. No special client app required on the accessing device.
*   **Secure File Sharing:** Upload, download, and manage files with PIN-based authentication.
*   **Easy Connection:** Connect quickly using a QR code or by manually entering the displayed IP address.
*   **IP Address Selection:** Choose which network interface (e.g., Wi-Fi, Tailscale) to use for serving files.
*   **Client-only Web App:** The web version of LocalNode functions as a client to access servers running on other platforms.

## 🚀 Getting Started

### Installation

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
    (Note: For web, run `flutter run -d chrome`. The web version runs in client-only mode.)

### Usage

1.  **Start the Server:** Launch the app on your desired server device (iOS, Android, Windows, macOS, or Linux).
2.  **Select IP (Optional):** On the app's home screen, you can select the IP address you wish to use for the server if your device has multiple network interfaces.
3.  **Scan QR or Enter Address:** Open a web browser on another device on the same network and either scan the QR code displayed in the app or manually enter the URL (e.g., `http://192.168.1.10:8080`).
4.  **Authenticate:** Enter the PIN displayed in the app to access your files.
5.  **Manage Files:** You can now upload, download, and manage files directly from your web browser.

## 💻 Platform Support

*   **iOS:** Full server functionality.
*   **Android:** Full server functionality.
*   **Windows:** Full server functionality.
*   **macOS:** Full server functionality.
*   **Linux:** Full server functionality.
*   **Web:** Client-only mode (connects to a server running on another platform).

## 🤝 Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.