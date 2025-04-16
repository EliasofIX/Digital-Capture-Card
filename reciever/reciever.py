import sys
import subprocess
from PySide6.QtWidgets import (
    QApplication,
    QWidget,
    QLabel,
    QVBoxLayout,
    QPushButton,
)
from PySide6.QtCore import QProcess, Qt, QTimer
from PySide6.QtGui import QPalette, QColor


# --- Configuration ---
FFPLAY_PATH = "ffplay"  # Assumes ffplay is in the system PATH
UDP_PORT = 5555
FFPLAY_WINDOW_TITLE = "LINKPLAY Stream (Capture This Window in OBS)"
# --- End Configuration ---


class ReceiverWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.ffplay_process = None
        self.init_ui()
        self.start_ffplay()

    def init_ui(self):
        self.setWindowTitle("LINKPLAY Receiver")
        self.setGeometry(100, 100, 400, 150)  # x, y, width, height

        # Set dark background
        palette = self.palette()
        palette.setColor(QPalette.ColorRole.Window, QColor(45, 45, 45))
        palette.setColor(QPalette.ColorRole.WindowText, QColor(220, 220, 220))
        self.setPalette(palette)
        self.setAutoFillBackground(True)

        self.layout = QVBoxLayout()

        self.status_label = QLabel("Initializing...")
        self.status_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        font = self.status_label.font()
        font.setPointSize(14)
        self.status_label.setFont(font)
        self.layout.addWidget(self.status_label)

        self.restart_button = QPushButton("Restart ffplay")
        self.restart_button.clicked.connect(self.restart_ffplay)
        self.restart_button.setEnabled(False) # Enable only when stopped/failed
        self.layout.addWidget(self.restart_button)

        self.setLayout(self.layout)
        self.show()

    def start_ffplay(self):
        if self.ffplay_process and self.ffplay_process.state() == QProcess.ProcessState.Running:
            print("ffplay is already running.")
            return

        self.status_label.setText(f"Attempting to start ffplay...")
        self.restart_button.setEnabled(False)

        self.ffplay_process = QProcess(self)
        self.ffplay_process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels) # Combine stdout/stderr

        # Connect signals
        self.ffplay_process.started.connect(self.on_ffplay_started)
        self.ffplay_process.finished.connect(self.on_ffplay_finished)
        self.ffplay_process.errorOccurred.connect(self.on_ffplay_error)
        # self.ffplay_process.readyReadStandardOutput.connect(self.handle_output) # Optional: Read ffplay output

        # --- ffplay Arguments ---
        # -fflags nobuffer: Reduce latency by not buffering input
        # -flags low_delay: Reduce latency further
        # -framedrop: Drop frames if decoding falls behind (helps sync)
        # -strict experimental: Needed for some low latency options
        # -window_title: Set a specific title for easy OBS capture
        # -i udp://@:{UDP_PORT}: Input source (listen on specified UDP port on all interfaces)
        # -sync ext: Sync video to external clock (less drift, might not be needed)
        # -an / -vn : Disable audio/video if needed
        # -infbuf: Don't limit input buffer size (can help with network jitter but uses more RAM)

        arguments = [
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-framedrop",
            "-strict", "experimental",
            "-window_title", FFPLAY_WINDOW_TITLE,
            # "-sync", "ext", # Optional: experiment if you have sync issues
            "-infbuf", # Optional: might help if stream stutters initially
            "-i", f"udp://@:{UDP_PORT}",
        ]

        print(f"Starting: {FFPLAY_PATH} {' '.join(arguments)}")
        self.ffplay_process.start(FFPLAY_PATH, arguments)

        # Check immediately if executable exists (errorOccurred might be delayed)
        if self.ffplay_process.state() == QProcess.ProcessState.NotRunning:
             # Give it a tiny moment in case errorOccurred is slightly delayed
             QTimer.singleShot(100, self.check_if_started_failed)


    def check_if_started_failed(self):
         # If after a short delay it's still not running and no error signal fired yet
         if self.ffplay_process and self.ffplay_process.state() == QProcess.ProcessState.NotRunning:
              # Check common reason: command not found
              try:
                   # Simple check if ffplay exists in PATH
                   subprocess.check_output(["which", FFPLAY_PATH])
                   # If above works, the error is something else
                   self.status_label.setText("Error: ffplay failed to start (Unknown reason)")
              except (subprocess.CalledProcessError, FileNotFoundError):
                   # Most likely ffplay not found
                   self.status_label.setText(f"Error: '{FFPLAY_PATH}' not found in PATH.\nInstall FFmpeg (brew install ffmpeg).")
              self.restart_button.setEnabled(True)


    def on_ffplay_started(self):
        self.status_label.setText(f"ffplay running.\nWaiting for stream on UDP port {UDP_PORT}...")
        print("ffplay process started successfully.")
        self.restart_button.setEnabled(False)

    def on_ffplay_finished(self, exit_code, exit_status):
        status_text = "ffplay stopped."
        if exit_status == QProcess.ExitStatus.CrashExit:
            status_text = f"ffplay crashed (Exit code: {exit_code})."
        else:
            status_text = f"ffplay finished (Exit code: {exit_code})."
        print(status_text)
        self.status_label.setText(status_text + "\nClick Restart to try again.")
        self.ffplay_process = None # Clear the process reference
        self.restart_button.setEnabled(True)


    def on_ffplay_error(self, error):
        error_string = self.ffplay_process.errorString()
        print(f"ffplay error: {error} - {error_string}")
        if error == QProcess.ProcessError.FailedToStart:
             self.status_label.setText(f"Error: Failed to start '{FFPLAY_PATH}'.\nIs FFmpeg installed and in PATH?\n({error_string})")
        else:
             self.status_label.setText(f"ffplay Error: {error_string}")
        self.ffplay_process = None
        self.restart_button.setEnabled(True)

    # Optional: Read ffplay's console output
    # def handle_output(self):
    #     data = self.ffplay_process.readAllStandardOutput().data().decode()
    #     print(f"ffplay output: {data.strip()}")

    def restart_ffplay(self):
        print("Restart button clicked.")
        if self.ffplay_process and self.ffplay_process.state() != QProcess.ProcessState.NotRunning:
            print("Terminating existing ffplay process before restart...")
            self.ffplay_process.terminate()
            if not self.ffplay_process.waitForFinished(1000): # Wait 1 sec
                 print("Force killing ffplay process...")
                 self.ffplay_process.kill()
                 self.ffplay_process.waitForFinished(500) # Wait briefly after kill
            self.ffplay_process = None # Ensure it's cleared

        # Use QTimer to ensure the event loop processes the termination before starting again
        QTimer.singleShot(100, self.start_ffplay)


    def closeEvent(self, event):
        """Ensure ffplay is terminated when the window closes."""
        print("Close event triggered. Stopping ffplay...")
        if self.ffplay_process and self.ffplay_process.state() == QProcess.ProcessState.Running:
            self.ffplay_process.terminate()
            # Wait a short time for graceful termination
            if not self.ffplay_process.waitForFinished(1000):
                print("ffplay did not terminate gracefully, killing...")
                self.ffplay_process.kill()
                self.ffplay_process.waitForFinished(500) # Wait after kill
        event.accept() # Accept the close event


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = ReceiverWindow()
    sys.exit(app.exec())

