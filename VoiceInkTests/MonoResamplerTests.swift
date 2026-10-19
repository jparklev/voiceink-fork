import Foundation
import Testing
@testable import VoiceInk

struct MonoResamplerTests {
    // Feeds 1 s of 48 kHz audio in 512-frame callbacks, as the AUHAL does.
    private func resample(_ frequency: Float) throws -> [Int16] {
        let resampler = try MonoResampler(inputRate: 48_000, outputRate: 16_000)
        let input = (0..<48_000).map { 0.5 * sin(2 * .pi * frequency * Float($0) / 48_000) }
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        var output: [Int16] = []
        for start in stride(from: 0, to: input.count, by: 512) {
            let frames = min(512, input.count - start)
            let produced = input.withUnsafeBufferPointer { resampler.process($0.baseAddress! + start, frames: UInt32(frames), into: buffer, capacity: 4096) }
            output += UnsafeBufferPointer(start: buffer, count: Int(produced))
        }
        return output
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot() / 32767
    }

    @Test func keepsDurationAcrossCallbacks() throws {
        #expect(abs(try resample(440).count - 16_000) <= 64)
    }

    @Test func passesSpeechAndFiltersAboveNyquist() throws {
        #expect(abs(rms(try resample(440)[2000..<14000]) - 0.5 / 2.squareRoot()) < 0.01)
        #expect(rms(try resample(12_000)[2000..<14000]) < 0.01)
    }
}
