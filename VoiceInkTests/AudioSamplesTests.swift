import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

struct AudioSamplesTests {
    private func writeSine(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func decodes16kMonoWithoutHeaderBytesOrNormalization() throws {
        let samples = try AudioProcessor.samples16kMono(from: writeSine(sampleRate: 16_000, channels: 1, seconds: 1))
        #expect(samples.count == 16_000)
        #expect(abs(samples[0]) < 0.001)
        #expect(abs((samples.map(abs).max() ?? 0) - 0.5) < 0.01)
    }

    @Test func resamplesAndDownmixesOtherFormats() throws {
        let samples = try AudioProcessor.samples16kMono(from: writeSine(sampleRate: 44_100, channels: 2, seconds: 1))
        #expect(abs(samples.count - 16_000) <= 32)
        #expect(abs((samples.map(abs).max() ?? 0) - 0.5) < 0.02)
    }
}
