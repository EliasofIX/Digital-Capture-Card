# LINKPLAY - Software HDMI Cable

LINKPLAY is a simple "software HDMI cable" solution designed to stream the screen content of a Windows gaming laptop to a macOS computer over a local network. The primary goal is to enable gameplay on the Windows machine while using OBS Studio on the macOS machine for streaming or recording, without requiring a physical capture card.

It consists of two parts:
1.  **LINKPLAY Sender (Windows):** A C++ command-line application that captures the desktop, encodes it using NVIDIA's NVENC (via FFmpeg), and streams it over UDP.
2.  **LINKPLAY Receiver (macOS):** A Python application with a minimal Qt (PySide6) GUI that launches `ffplay` (part of FFmpeg) to receive the UDP stream and display it in a window, which can then be captured by OBS.

## How it Works

1.  The **Sender** runs on the Windows PC. It uses FFmpeg's `gdigrab` to capture the entire desktop at 60 FPS.
2.  FFmpeg, controlled by the Sender application, encodes the captured video using the GPU-accelerated `h264_nvenc` encoder with low-latency settings.
3.  The encoded video is packaged into an MPEG Transport Stream (`mpegts`) and sent over the network via UDP to the specified IP address and port of the macOS machine.
4.  The **Receiver** runs on the macOS machine. It provides a simple status window and launches the `ffplay` command-line tool in a separate process.
5.  `ffplay` listens on the specified UDP port, receives the stream, decodes it with low latency options, and displays the video in its own window.
6.  **OBS Studio** on the macOS machine uses a "Window Capture" source to capture the video displayed in the `ffplay` window.

## Requirements

**Windows (Sender):**

*   Windows 10 or 11
*   **NVIDIA GPU** with NVENC support (most modern NVIDIA GPUs)
*   Latest **NVIDIA Drivers** installed
*   **FFmpeg:** A recent static build *with NVENC enabled*. Download from [Gyan.dev](https://www.gyan.dev/ffmpeg/builds/) or [BtbN](https://github.com/BtbN/FFmpeg-Builds/releases). Extract `ffmpeg.exe` and either add its location to your system's PATH environment variable or place it in the same directory as `sender.exe`.
*   **C++ Compiler:**
    *   Microsoft Visual Studio (with "Desktop development with C++" workload) OR
    *   MinGW-w64 (e.g., via MSYS2)

**macOS (Receiver):**

*   macOS (tested on recent versions)
*   **Python 3:** Usually pre-installed. Check with `python3 --version`. If needed, install from [python.org](https://www.python.org/downloads/macos/).
*   **Homebrew:** Package manager for macOS. Install from [brew.sh](https://brew.sh/).
*   **FFmpeg:** Required for the `ffplay` command. Install via Homebrew:
    ```bash
    brew install ffmpeg
    ```
*   **PySide6:** Qt for Python library. Install via pip:
    ```bash
    pip3 install PySide6
    ```

**Network:**

*   Both computers connected to the same local network.
*   **Wired Ethernet connection or USB-C IP Tethering is strongly recommended** for best performance and lowest latency. Wi-Fi may introduce significant lag or stuttering.
*   Firewalls on both machines must allow UDP traffic on the chosen port (default: 5555).

## Installation / Setup

**1. LINKPLAY Sender (Windows):**

*   Ensure FFmpeg is downloaded and accessible (in PATH or same directory).
*   Ensure NVIDIA drivers are up-to-date.
*   Save the C++ code as `sender.cpp`.
*   Compile `sender.cpp`:
    *   **Using MSVC (Developer Command Prompt):**
        ```bash
        cl /EHsc /std:c++17 sender.cpp /Fe:sender.exe
        ```
    *   **Using g++ (MinGW/MSYS2):**
        ```bash
        g++ sender.cpp -o sender.exe -static -lstdc++ -static-libgcc -std=c++17
        ```
    *   This will create `sender.exe`.

**2. LINKPLAY Receiver (macOS):**

*   Install Homebrew (if not already installed).
*   Install FFmpeg: `brew install ffmpeg`
*   Install PySide6: `pip3 install PySide6`
*   Save the Python code as `receiver.py`.

## Usage

1.  **Find macOS IP Address:**
    *   On your Mac, go to **System Settings** -> **Network**.
    *   Select your active connection (Ethernet/Wi-Fi/USB).
    *   Note the **IPv4 Address** (e.g., `192.168.1.150`).

2.  **Start Sender (on Windows):**
    *   Open Command Prompt or PowerShell.
    *   Navigate (`cd`) to the directory containing `sender.exe`.
    *   Run the sender, providing the Mac's IP address:
        ```bash
        .\sender.exe YOUR_MAC_IP_ADDRESS
        ```
        *(Example: `.\sender.exe 192.168.1.150`)*
    *   The console will show the FFmpeg command being executed and indicate that streaming has started. Leave this window open.

3.  **Start Receiver (on macOS):**
    *   Open the Terminal app.
    *   Navigate (`cd`) to the directory containing `receiver.py`.
    *   Run the receiver script:
        ```bash
        python3 receiver.py
        ```
    *   A small status window ("LINKPLAY Receiver") will appear.
    *   If the sender is running, a *second* window titled "LINKPLAY Stream (Capture This Window in OBS)" should appear shortly after, launched by `ffplay`. This window will display the video stream from Windows.

4.  **Configure OBS (on macOS):**
    *   Open OBS Studio.
    *   Add a new **Window Capture** source.
    *   In the source properties:
        *   **Window:** Select `[ffplay] LINKPLAY Stream (Capture This Window in OBS)`. **Do not select the Python status window.**
        *   **Window Match Priority:** Should default correctly, but ensure it matches the title.
        *   **Show Window Shadow:** **Uncheck** this option.
        *   Click **OK**.
    *   Resize and position the source in your OBS scene. You should see your Windows desktop.

5.  **Stopping:**
    *   **Sender:** Press `Ctrl+C` in the Command Prompt/PowerShell window on Windows.
    *   **Receiver:** Close the "LINKPLAY Receiver" status window on macOS (this will also terminate the `ffplay` process).

## Troubleshooting

*   **No Video in `ffplay` Window:**
    *   Verify the IP address used for the Sender matches the Mac's current IP.
    *   Ensure both devices are on the *exact same* network.
    *   Check firewalls on both Windows and macOS. Allow incoming UDP traffic on port `5555` on the Mac.
    *   Make sure the Sender (`sender.exe`) is still running on Windows and didn't exit with an error.
*   **Laggy/Choppy Video:**
    *   **USE WIRED ETHERNET OR USB-C TETHERING.** Wi-Fi is often unreliable for low-latency streaming.
    *   Check for other network-intensive applications running.
    *   Monitor CPU/GPU usage on both machines. The Windows PC needs resources for the game *and* encoding.
    *   Try adjusting encoding parameters in `sender.cpp` (e.g., lower `-framerate` or use `-b:v 15M` instead of `-qp 0` if bandwidth is suspected, though `-qp 0` is generally better for latency if bandwidth allows).
*   **Sender Fails to Start (NVENC Error):**
    *   Ensure you have a compatible NVIDIA GPU.
    *   Update NVIDIA drivers.
    *   Make sure the downloaded FFmpeg build explicitly supports NVENC.
*   **Receiver Error: `ffplay` not found:**
    *   Ensure you ran `brew install ffmpeg` successfully on the Mac.
    *   Try running `ffplay` directly in the Mac Terminal to see if the command is recognized. If not, Homebrew might not be configured correctly in your PATH.
*   **Receiver Error: Failed to start `ffplay` (Unknown reason):**
    *   Check permissions or other system issues that might prevent Python from launching subprocesses.


