#include <iostream>
#include <string>
#include <vector>
#include <windows.h> // For CreateProcess
#include <cstdio>    // For _popen, _pclose
#include <stdexcept> // For runtime_error
#include <sstream>   // For string stream

// --- Configuration ---
const std::string DEFAULT_TARGET_IP = "192.168.1.100"; // Default Mac IP
const int TARGET_PORT = 5555;
const int FRAME_RATE = 60;
// --- End Configuration ---

// Function to execute a command and capture its output (simplified)
std::string exec(const char* cmd) {
    char buffer[128];
    std::string result = "";
    FILE* pipe = _popen(cmd, "r"); // Execute command for reading
    if (!pipe) throw std::runtime_error("_popen() failed!");
    try {
        while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
            result += buffer;
        }
    } catch (...) {
        _pclose(pipe);
        throw;
    }
    _pclose(pipe);
    return result;
}

// Function to check if NVENC encoder is available via FFmpeg
bool checkNvencAvailable() {
    try {
        // Use findstr (Windows equivalent of grep) to check encoder list
        std::string command = "ffmpeg -hide_banner -encoders | findstr h264_nvenc";
        std::cout << "Checking for NVENC availability..." << std::endl;
        std::string output = exec(command.c_str());
        if (output.find("h264_nvenc") != std::string::npos) {
            std::cout << "NVENC encoder found." << std::endl;
            return true;
        } else {
            std::cerr << "Error: h264_nvenc encoder not found by FFmpeg." << std::endl;
            std::cerr << "Please ensure you have NVIDIA drivers installed and an FFmpeg build with NVENC enabled." << std::endl;
            return false;
        }
    } catch (const std::exception& e) {
        std::cerr << "Error checking for NVENC: " << e.what() << std::endl;
        std::cerr << "Is FFmpeg installed and in your system's PATH?" << std::endl;
        return false;
    }
}


int main(int argc, char* argv[]) {
    std::string targetIp = DEFAULT_TARGET_IP;

    // --- Argument Parsing (Optional Bonus) ---
    if (argc > 1) {
        targetIp = argv[1];
        std::cout << "Using target IP from command line: " << targetIp << std::endl;
    } else {
        std::cout << "Using default target IP: " << targetIp << std::endl;
    }
    // --- End Argument Parsing ---

    // --- Check for NVENC ---
    if (!checkNvencAvailable()) {
        return 1; // Exit if NVENC is not available
    }
    // --- End NVENC Check ---


    // --- Construct FFmpeg Command ---
    std::stringstream ffmpegCmdStream;
    ffmpegCmdStream << "ffmpeg -hide_banner " // Suppress banner for cleaner output
                    << "-f gdigrab "          // Input format: GDI screen capture
                    << "-framerate " << FRAME_RATE << " " // Capture frame rate
                    << "-i desktop "          // Input source: the entire desktop
                    << "-c:v h264_nvenc "     // Video codec: NVIDIA H.264 encoder
                    << "-preset p1 "          // NVENC preset: p1 is fastest (ultrafast equivalent)
                    << "-tune ll "            // NVENC tuning: low latency
                    << "-qp 0 "               // Constant Quantization Parameter (0 = lossless, adjust if needed for bandwidth)
                                              // Alternatively use -b:v for bitrate control e.g., "-b:v 20M"
                    << "-rc constqp "         // Rate control mode for -qp
                    << "-f mpegts "           // Output format: MPEG Transport Stream (good for UDP)
                    << "udp://" << targetIp << ":" << TARGET_PORT; // Output destination

    std::string ffmpegCmd = ffmpegCmdStream.str();
    std::cout << "\nExecuting FFmpeg command:\n" << ffmpegCmd << "\n" << std::endl;

    // --- Execute FFmpeg using CreateProcess ---
    STARTUPINFOA si; // Use STARTUPINFOA for char* command line
    PROCESS_INFORMATION pi;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    // Need a mutable char array for CreateProcess's lpCommandLine
    std::vector<char> cmdVec(ffmpegCmd.begin(), ffmpegCmd.end());
    cmdVec.push_back('\0'); // Null-terminate the string

    // Start the child process.
    if (!CreateProcessA(NULL,        // No module name (use command line)
                        cmdVec.data(), // Command line (mutable)
                        NULL,        // Process handle not inheritable
                        NULL,        // Thread handle not inheritable
                        FALSE,       // Set handle inheritance to FALSE
                        0,           // No creation flags (can use CREATE_NO_WINDOW)
                        NULL,        // Use parent's environment block
                        NULL,        // Use parent's starting directory
                        &si,         // Pointer to STARTUPINFO structure
                        &pi)         // Pointer to PROCESS_INFORMATION structure
    ) {
        std::cerr << "CreateProcess failed (" << GetLastError() << ").\n";
        std::cerr << "Ensure ffmpeg.exe is in your system's PATH or in the same directory as sender.exe." << std::endl;
        return 1;
    }

    std::cout << "Streaming started... Press Ctrl+C in this window to stop." << std::endl;

    // Wait until child process exits.
    WaitForSingleObject(pi.hProcess, INFINITE);

    std::cout << "Streaming stopped." << std::endl;

    // Close process and thread handles.
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    return 0;
}

