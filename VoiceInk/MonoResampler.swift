import AudioToolbox
import Foundation

/// Converts mono Float32 at the device rate to mono Int16 at the output rate. Unlike per-buffer
/// interpolation it low-pass filters and keeps phase across callbacks. Allocates only in init.
final class MonoResampler {
    private struct Pending {
        var data: UnsafePointer<Float32>?
        var frames: UInt32
    }

    private var converter: AudioConverterRef?
    private let pending = UnsafeMutablePointer<Pending>.allocate(capacity: 1)

    init(inputRate: Double, outputRate: Double) throws {
        var input = AudioStreamBasicDescription(mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: outputRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        pending.initialize(to: Pending(data: nil, frames: 0))
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, let converter else {
            pending.deallocate()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var quality = kAudioConverterQuality_High
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, UInt32(MemoryLayout<UInt32>.size), &quality)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        pending.deallocate()
    }

    /// Returns the number of frames written to `output`; it varies by a frame or so between calls.
    func process(_ input: UnsafePointer<Float32>, frames: UInt32, into output: UnsafeMutablePointer<Int16>, capacity: UInt32) -> UInt32 {
        guard let converter else { return 0 }
        pending.pointee = Pending(data: input, frames: frames)
        var produced = capacity
        var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity * 2, mData: output))
        // The input proc hands over this callback's frames once, then reports "no data yet" (status 1)
        // so the converter returns what it has and keeps the remainder for the next call.
        _ = AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, userData in
            let pending = userData!.assumingMemoryBound(to: Pending.self)
            guard pending.pointee.frames > 0, let data = pending.pointee.data else {
                ioPackets.pointee = 0
                return 1
            }
            ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: pending.pointee.frames * 4,
                                                  mData: UnsafeMutableRawPointer(mutating: data))
            ioPackets.pointee = pending.pointee.frames
            pending.pointee.frames = 0
            return noErr
        }, pending, &produced, &outputList, nil)
        return produced
    }
}
