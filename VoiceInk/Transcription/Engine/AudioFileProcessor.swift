import Foundation
import AVFoundation
import os

class AudioProcessor {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioProcessor")
    
    struct AudioFormat {
        static let targetSampleRate: Double = 16000.0
        static let targetChannels: UInt32 = 1
        static let targetBitDepth: UInt32 = 16
    }
    
    enum AudioProcessingError: LocalizedError {
        case invalidAudioFile
        case conversionFailed
        case exportFailed
        case unsupportedFormat
        case sampleExtractionFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidAudioFile:
                return "The audio file is invalid or corrupted"
            case .conversionFailed:
                return "Failed to convert the audio format"
            case .exportFailed:
                return "Failed to export the processed audio"
            case .unsupportedFormat:
                return "The audio format is not supported"
            case .sampleExtractionFailed:
                return "Failed to extract audio samples"
            }
        }
    }
    
    func processAudioToSamples(_ url: URL) async throws -> [Float] {
        try Self.samples16kMono(from: url)
    }

    /// Decodes any file AVAudioFile can read into 16 kHz mono Float32 samples.
    static func samples16kMono(from url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AudioProcessingError.invalidAudioFile
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.targetSampleRate,
                                               channels: AudioFormat.targetChannels, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw AudioProcessingError.unsupportedFormat
        }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 65_536
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk) else {
            throw AudioProcessingError.conversionFailed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * AudioFormat.targetSampleRate / file.processingFormat.sampleRate))
        var readError: Error?
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                do {
                    guard file.framePosition < file.length else { throw CocoaError(.fileReadUnknown) }
                    try file.read(into: input, frameCount: chunk)
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    if file.framePosition < file.length { readError = error }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if error != nil || readError != nil || status == .error {
                throw AudioProcessingError.sampleExtractionFailed
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { return samples }
        }
    }

    func saveSamplesAsWav(samples: [Float], to url: URL) throws {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: true
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
        
        guard let buffer = buffer else {
            throw AudioProcessingError.conversionFailed
        }
        
        // Convert float samples to int16
        let int16Samples = samples.map { max(-1.0, min(1.0, $0)) * Float(Int16.max) }.map { Int16($0) }

        // Copy samples to buffer
        int16Samples.withUnsafeBufferPointer { int16Buffer in
            let int16Pointer = int16Buffer.baseAddress!
            buffer.int16ChannelData![0].update(from: int16Pointer, count: int16Samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Create audio file
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        try audioFile.write(from: buffer)
    }
} 

