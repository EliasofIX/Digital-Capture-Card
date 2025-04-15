import SwiftUI

struct ContentView: View {
    // Use a StateObject to keep the decoder alive
    @StateObject private var decoder = Decoder()
    @State private var errorMessage: String? = nil
    @State private var showInfoOverlay = true // Show IP/Port initially

    let listenPort = 5555 // Must match sender port

    var body: some View {
        ZStack {
            // The VideoViewRepresentable wraps our NSView for SwiftUI
            VideoViewRepresentable(cgImage: $decoder.currentFrame)
                .onAppear {
                    // Start decoding when the view appears
                    decoder.startDecoding(port: listenPort) { error in
                        // Handle errors reported by the decoder
                        DispatchQueue.main.async {
                            self.errorMessage = error
                            self.showInfoOverlay = true // Show overlay on error
                        }
                    }
                }
                .onDisappear {
                    // Stop decoding when the view disappears
                    decoder.stopDecoding()
                }
                .edgesIgnoringSafeArea(.all) // Allow video to fill the window

            // Overlay for status messages or errors
            if showInfoOverlay || errorMessage != nil {
                VStack {
                    if let error = errorMessage {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    } else if decoder.isDecoding {
                         Text("Receiving on UDP Port \(listenPort)...")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    } else {
                         Text("Waiting for stream on UDP Port \(listenPort)...")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    Spacer() // Pushes text to the top
                }
                .padding()
                .onTapGesture {
                    // Hide info overlay on tap if there's no error
                    if errorMessage == nil {
                        showInfoOverlay = false
                    }
                }
            }
        }
        // Optional: Add a way to toggle fullscreen (e.g., menu item or button)
        // This requires more AppKit/SwiftUI integration.
    }
}

// SwiftUI Representable to host the NSView-based VideoView
struct VideoViewRepresentable: NSViewRepresentable {
    @Binding var cgImage: CGImage?

    func makeNSView(context: Context) -> VideoView {
        return VideoView()
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        nsView.image = cgImage // Update the view when the binding changes
        // Trigger redraw
        nsView.needsDisplay = true
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


