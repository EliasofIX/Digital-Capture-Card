import Foundation
import CoreGraphics
import AppKit // For NSImage/CGImage conversion if needed, but we use CGImage directly

// Class to handle FFmpeg decoding
class Decoder: ObservableObject {
    // Published property to hold the latest decoded frame for SwiftUI view updates
    @Published var currentFrame: CGImage? = nil
    @Published var isDecoding: Bool = false

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>? = nil
    private var swsCtx: UnsafeMutablePointer<SwsContext>? = nil
    private var videoStreamIndex: Int32 = -1
    private var frame: UnsafeMutablePointer<AVFrame>? = nil
    private var rgbFrame: UnsafeMutablePointer<AVFrame>? = nil // Frame for RGB data
    private var buffer: UnsafeMutablePointer<UInt8>? = nil     // Buffer for RGB data

    private var decodingQueue = DispatchQueue(label: "linkplay.decoder.queue", qos: .userInitiated)
    private var stopDecodingFlag = false
    private var errorHandler: ((String) -> Void)?

    init() {
        // av_log_set_level(AV_LOG_VERBOSE) // Uncomment for detailed FFmpeg logs
        avformat_network_init() // Initialize networking capabilities
        print("Decoder Initialized")
    }

    deinit {
        print("Decoder Deinitializing")
        stopDecoding() // Ensure cleanup happens
        avformat_network_deinit()
    }

    // Start the decoding process on a background thread
    func startDecoding(port: Int, onError: @escaping (String) -> Void) {
        guard !isDecoding else { return }

        self.errorHandler = onError
        self.stopDecodingFlag = false
        isDecoding = true
        print("Starting decoding on port \(port)...")

        decodingQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.setupFFmpeg(port: port)
                self.runDecodingLoop()
            } catch let error as DecoderError {
                print("Decoder setup error: \(error.localizedDescription)")
                self.isDecoding = false
                self.errorHandler?(error.localizedDescription)
                self.cleanup() // Clean up resources on error
            } catch {
                print("Unexpected error: \(error)")
                 self.isDecoding = false
                 self.errorHandler?("An unexpected error occurred during setup.")
                 self.cleanup()
            }
        }
    }

    // Signal the decoding loop to stop
    func stopDecoding() {
        guard isDecoding else { return }
        print("Stopping decoding...")
        stopDecodingFlag = true
        // No need to explicitly join the queue, cleanup handles resources.
        // If the queue is blocked (e.g., network read), cleanup might take time.
        // Consider adding a timeout or more robust shutdown if needed.
        // For now, rely on cleanup being called eventually or on deinit.
        // We call cleanup directly here for faster resource release if possible.
        decodingQueue.async { [weak self] in
             self?.cleanup()
             self?.isDecoding = false
             print("Decoding stopped and resources cleaned up.")
        }
    }

    // Setup FFmpeg components
    private func setupFFmpeg(port: Int) throws {
        let address = "udp://@:\(port)" // Listen on all interfaces for the specified port
        print("Opening input: \(address)")

        // 1. Open Input
        var formatCtxPtr: UnsafeMutablePointer<AVFormatContext>? = nil
        var ret = avformat_open_input(&formatCtxPtr, address, nil, nil)
        guard ret == 0, let ctx = formatCtxPtr else {
            throw DecoderError.openInputFailed(errorCode: ret, url: address)
        }
        self.formatCtx = ctx
        print("Input opened.")

        // Set low latency flags (important for UDP streaming)
        av_dict_set(&formatCtx?.pointee.iformat?.pointee.priv_data, "fflags", "nobuffer", 0)
        av_dict_set(&formatCtx?.pointee.iformat?.pointee.priv_data, "flags", "low_delay", 0)


        // 2. Find Stream Info
        ret = avformat_find_stream_info(formatCtx, nil)
        guard ret >= 0 else {
            throw DecoderError.findStreamInfoFailed(errorCode: ret)
        }
        print("Stream info found.")

        // 3. Find Video Stream and Decoder
        videoStreamIndex = -1
        var codec: UnsafeMutablePointer<AVCodec>? = nil
        for i in 0..<Int(formatCtx!.pointee.nb_streams) {
            let stream = formatCtx!.pointee.streams[i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                let codecId = stream.pointee.codecpar.pointee.codec_id
                codec = avcodec_find_decoder(codecId)
                if codec == nil {
                    throw DecoderError.decoderNotFound(codecId: codecId)
                }
                print("Video stream found at index \(i), Codec: \(String(cString: avcodec_get_name(codecId)))")
                break
            }
        }
        guard videoStreamIndex != -1, let foundCodec = codec else {
            throw DecoderError.noVideoStream
        }

        // 4. Allocate Codec Context
        codecCtx = avcodec_alloc_context3(foundCodec)
        guard codecCtx != nil else {
            throw DecoderError.allocCodecContextFailed
        }

        // 5. Copy Codec Parameters
        ret = avcodec_parameters_to_context(codecCtx, formatCtx!.pointee.streams[Int(videoStreamIndex)]!.pointee.codecpar)
        guard ret >= 0 else {
            throw DecoderError.copyCodecParamsFailed(errorCode: ret)
        }

        // Enable low delay decoding
        av_opt_set(codecCtx?.pointee.priv_data, "flags", "low_delay", 0)
        codecCtx?.pointee.flags2 |= AV_CODEC_FLAG2_FAST // Allow non-spec compliant speedups

        // 6. Open Codec
        ret = avcodec_open2(codecCtx, foundCodec, nil)
        guard ret == 0 else {
            throw DecoderError.openCodecFailed(errorCode: ret)
        }
        print("Codec opened.")

        // 7. Allocate Frames
        frame = av_frame_alloc()
        rgbFrame = av_frame_alloc()
        guard frame != nil, rgbFrame != nil else {
            throw DecoderError.allocFrameFailed
        }

        // 8. Prepare SwsContext for color space conversion (e.g., YUV to BGRA)
        let width = codecCtx!.pointee.width
        let height = codecCtx!.pointee.height
        let pixFmt = codecCtx!.pointee.pix_fmt // Original format
        let dstPixFmt = AV_PIX_FMT_BGRA // Target format for CGImage

        print("Video dimensions: \(width)x\(height), Format: \(pixFmt)")

        swsCtx = sws_getContext(width, height, pixFmt,
                                width, height, dstPixFmt,
                                SWS_BILINEAR, nil, nil, nil) // Use bilinear scaling alg
        guard swsCtx != nil else {
            throw DecoderError.createSwsContextFailed
        }

        // Allocate buffer for the RGB frame data
        let numBytes = av_image_get_buffer_size(dstPixFmt, width, height, 1)
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(numBytes))
        av_image_fill_arrays(&rgbFrame!.pointee.data.0, &rgbFrame!.pointee.linesize.0,
                             buffer, dstPixFmt, width, height, 1)

        print("FFmpeg setup complete.")
    }

    // The main loop reading packets and decoding frames
    private func runDecodingLoop() {
        var packet = AVPacket()
        av_init_packet(&packet)
        defer { av_packet_unref(&packet) } // Ensure packet is unreferenced

        print("Starting decoding loop...")

        while !stopDecodingFlag {
            // Read frame packet
            let readRet = av_read_frame(formatCtx, &packet)
            if readRet < 0 {
                // EAGAIN means try again, others are errors or EOF
                if readRet == AVERROR(EAGAIN) {
                    // print("av_read_frame: EAGAIN")
                    Thread.sleep(forTimeInterval: 0.005) // Small sleep to avoid busy-waiting
                    continue
                } else {
                    print("av_read_frame error or EOF: \(readRet)")
                    errorHandler?("Stream ended or read error (\(readRet)).")
                    break // Exit loop on error or end of stream
                }
            }

            // Process only packets from the video stream
            if packet.stream_index == videoStreamIndex {
                // Send packet to decoder
                var ret = avcodec_send_packet(codecCtx, &packet)
                if ret < 0 {
                    print("Error sending packet to decoder: \(ret)")
                    // Handle specific errors like EAGAIN if needed
                    // continue // Or break depending on error
                }

                // Receive decoded frames
                while ret >= 0 {
                    ret = avcodec_receive_frame(codecCtx, frame)
                    if ret == AVERROR(EAGAIN) || ret == AVERROR_EOF {
                        // Need more packets or end of stream for this frame
                        break
                    } else if ret < 0 {
                        print("Error receiving frame from decoder: \(ret)")
                        // Consider breaking the inner loop on critical errors
                        break // Exit inner loop
                    }

                    // We have a decoded frame (likely in YUV format)
                    // Convert it to BGRA using SwsContext
                    sws_scale(swsCtx,
                              &frame!.pointee.data.0, &frame!.pointee.linesize.0,
                              0, codecCtx!.pointee.height,
                              &rgbFrame!.pointee.data.0, &rgbFrame!.pointee.linesize.0)

                    // Create CGImage from the BGRA data
                    if let cgImage = createCGImage(from: rgbFrame!, width: codecCtx!.pointee.width, height: codecCtx!.pointee.height) {
                        // Update the published property on the main thread
                        DispatchQueue.main.async { [weak self] in
                            self?.currentFrame = cgImage
                        }
                    }
                }
            }

            // Unreference the packet to release its data
            av_packet_unref(&packet)
        } // End while loop

        print("Exited decoding loop.")
        // Cleanup is usually called by stopDecoding or deinit
        // If loop exited unexpectedly, ensure cleanup happens
        if !stopDecodingFlag { // If exited due to error/EOF, not explicit stop
             DispatchQueue.main.async { [weak self] in
                 self?.isDecoding = false
                 // Don't call cleanup here directly, let stopDecoding/deinit handle it
             }
        }
    }

    // Create a CGImage from an AVFrame containing BGRA data
    private func createCGImage(from frame: UnsafeMutablePointer<AVFrame>, width: Int32, height: Int32) -> CGImage? {
        let data = frame.pointee.data.0! // Pointer to BGRA data
        let linesize = Int(frame.pointee.linesize.0) // Bytes per row

        // Ensure data is treated as non-mutable for CGDataProvider
        let dataProvider = CGDataProvider(dataInfo: nil, data: data, size: linesize * Int(height)) { _, _, _ in
            // We manage the buffer manually, so no release callback needed here
            // If buffer ownership were transferred, this would free it.
        }

        guard let provider = dataProvider else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little, // BGRA on little-endian systems (like macOS)
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue) // BGRA
        ]

        return CGImage(width: Int(width),
                       height: Int(height),
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: linesize,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }


    // Clean up FFmpeg resources
    private func cleanup() {
        print("Cleaning up FFmpeg resources...")

        // Use a temporary variable to avoid race conditions if called concurrently
        // Although it should be called from the decoding queue or deinit
        let wasDecoding = self.isDecoding
        self.isDecoding = false // Mark as not decoding immediately

        // Free frames
        av_frame_free(&frame)
        av_frame_free(&rgbFrame)
        frame = nil
        rgbFrame = nil

        // Free buffer for RGB data
        buffer?.deallocate()
        buffer = nil

        // Free SwsContext
        sws_freeContext(swsCtx)
        swsCtx = nil

        // Close codec context
        if codecCtx != nil {
            avcodec_close(codecCtx)
            avcodec_free_context(&codecCtx)
            codecCtx = nil
        }

        // Close input format context
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
            // formatCtx is already set to nil by avformat_close_input via the pointer
            formatCtx = nil
        }

        // Reset state variables
        videoStreamIndex = -1
        currentFrame = nil // Clear the last frame
        errorHandler = nil

        print("Cleanup finished.")
    }
}

// Custom Error Enum for clarity
enum DecoderError: Error, LocalizedError {
    case openInputFailed(errorCode: Int32, url: String)
    case findStreamInfoFailed(errorCode: Int32)
    case noVideoStream
    case decoderNotFound(codecId: AVCodecID)
    case allocCodecContextFailed
    case copyCodecParamsFailed(errorCode: Int32)
    case openCodecFailed(errorCode: Int32)
    case allocFrameFailed
    case createSwsContextFailed

    var errorDescription: String? {
        switch self {
        case .openInputFailed(let code, let url):
            return "Failed to open input URL '\(url)'. FFmpeg error code: \(avErr2str(code)) (\(code)). Check network/firewall and sender."
        case .findStreamInfoFailed(let code):
            return "Failed to find stream info. FFmpeg error code: \(avErr2str(code)) (\(code)). Is the stream valid?"
        case .noVideoStream:
            return "Could not find a video stream in the input."
        case .decoderNotFound(let codecId):
            let codecName = String(cString: avcodec_get_name(codecId) ?? "Unknown")
            return "Could not find decoder for codec ID \(codecId) (\(codecName))."
        case .allocCodecContextFailed:
            return "Failed to allocate codec context."
        case .copyCodecParamsFailed(let code):
            return "Failed to copy codec parameters. FFmpeg error code: \(avErr2str(code)) (\(code))."
        case .openCodecFailed(let code):
            return "Failed to open codec. FFmpeg error code: \(avErr2str(code)) (\(code))."
        case .allocFrameFailed:
            return "Failed to allocate AVFrame."
        case .createSwsContextFailed:
            return "Failed to create SwsContext for color space conversion."
        }
    }
}

// Helper function to convert FFmpeg error codes to strings
func avErr2str(_ errnum: Int32) -> String {
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(AV_ERROR_MAX_STRING_SIZE))
    defer { buf.deallocate() }
    av_strerror(errnum, buf, Int(AV_ERROR_MAX_STRING_SIZE))
    return String(cString: buf)
}

