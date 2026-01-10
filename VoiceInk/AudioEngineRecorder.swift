import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import os

/// Output-First Warmup Audio Engine Architecture
///
/// The engine starts at app launch WITHOUT an input tap. This warms up the audio
/// hardware and allocates resources, but doesn't trigger the microphone privacy
/// indicator (orange dot). When recording starts, the input tap is quickly attached
/// (~50ms), and when recording stops, the tap is removed. This provides:
/// - Fast recording startup (engine already warmed)
/// - No persistent microphone indicator when not recording
@MainActor
class AudioEngineRecorder: ObservableObject {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioEngineRecorder")

    // Engine is kept alive continuously after prepare() is called
    // These are accessed from engineQueue and must be protected
    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var inputNode: AVAudioInputNode?
    nonisolated(unsafe) private var isEngineRunning = false
    nonisolated(unsafe) private var hasTapInstalled = false
    nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?

    // Recording state (separate from engine lifecycle)
    nonisolated(unsafe) private var audioFile: AVAudioFile?
    nonisolated(unsafe) private var recordingFormat: AVAudioFormat?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var _isRecording = false
    nonisolated(unsafe) private var hasReceivedValidBuffer = false

    private var recordingURL: URL?
    private var validationTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?

    @Published var currentAveragePower: Float = -160.0
    @Published var currentPeakPower: Float = -160.0
    @Published var isPrepared = false

    private let tapBufferSize: AVAudioFrameCount = 4096
    private let tapBusNumber: AVAudioNodeBus = 0

    // Serial queue for all engine operations to prevent race conditions
    private let engineQueue = DispatchQueue(label: "com.prakashjoshipax.VoiceInk.audioEngine", qos: .userInteractive)
    private let audioProcessingQueue = DispatchQueue(label: "com.prakashjoshipax.VoiceInk.audioProcessing", qos: .userInitiated)
    private let fileWriteLock = NSLock()

    var onRecordingError: ((Error) -> Void)?
    var onEngineRestarted: (() -> Void)?

    /// Prepare the audio engine at app launch. Call this once during app initialization.
    /// This warms up the engine WITHOUT triggering the microphone indicator.
    func prepare() {
        engineQueue.async { [weak self] in
            self?.prepareEngineSync()
        }
    }

    nonisolated private func prepareEngineSync() {
        let startTime = DispatchTime.now()

        // Create engine if needed
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
            logger.info("⏱️ AudioEngineRecorder engine created")
        }

        guard let engine = audioEngine else { return }

        // IMPORTANT: Do NOT access engine.inputNode here!
        // Accessing inputNode triggers microphone hardware initialization
        // and shows the privacy indicator. We only access it when recording starts.

        // Access mainMixerNode to create a valid output graph
        // This is required for engine.prepare() to succeed
        _ = engine.mainMixerNode

        // Prepare and start the engine (output-only graph)
        // This warms up audio hardware without triggering mic indicator
        engine.prepare()

        do {
            try engine.start()
            isEngineRunning = true
            let elapsed = (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
            logger.info("✅ Audio engine warmed (output-only, no mic indicator) (\(elapsed)ms)")

            Task { @MainActor [weak self] in
                self?.isPrepared = true
            }
        } catch {
            logger.error("Failed to start audio engine during prepare: \(error.localizedDescription)")
        }

        // Observe configuration changes (device switches, sample rate changes)
        setupConfigurationObserver()
    }

    nonisolated private func setupConfigurationObserver() {
        // Remove existing observer
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    nonisolated private func handleConfigurationChange() {
        logger.info("🔄 Audio engine configuration changed - reconfiguring...")

        engineQueue.async { [weak self] in
            guard let self = self else { return }

            // Read recording state under lock to avoid race
            self.fileWriteLock.lock()
            let wasRecording = self._isRecording
            self.fileWriteLock.unlock()

            // Stop engine gracefully
            if self.hasTapInstalled {
                self.inputNode?.removeTap(onBus: self.tapBusNumber)
                self.hasTapInstalled = false
                self.inputNode = nil
            }
            self.audioEngine?.stop()
            self.isEngineRunning = false

            // Small delay to let hardware settle
            Thread.sleep(forTimeInterval: 0.1)

            // Reinitialize the engine
            self.audioEngine = nil
            self.prepareEngineSync()

            // Notify that engine was restarted (Recorder can handle active recording recovery)
            if wasRecording {
                Task { @MainActor [weak self] in
                    self?.onEngineRestarted?()
                }
            }
        }
    }

    func startRecording(toOutputFile url: URL, retryCount: Int = 0) throws {
        let startTime = DispatchTime.now()
        hasReceivedValidBuffer = false

        // Serialize with engineQueue to prevent racing with handleConfigurationChange
        var inputFormat: AVAudioFormat?

        try engineQueue.sync { [weak self] in
            guard let self = self else {
                throw AudioEngineRecorderError.failedToStartEngine(NSError(domain: "AudioEngineRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Recorder deallocated"]))
            }

            // Ensure engine exists
            if self.audioEngine == nil {
                self.prepareEngineSync()
            }

            guard let engine = self.audioEngine else {
                throw AudioEngineRecorderError.failedToStartEngine(NSError(domain: "AudioEngineRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine not available"]))
            }

            // Stop engine to reconfigure with input tap
            if self.isEngineRunning {
                engine.stop()
                self.isEngineRunning = false
            }

            // Access inputNode NOW (this is when mic indicator appears)
            let input = engine.inputNode
            self.inputNode = input

            // Remove any existing tap
            if self.hasTapInstalled {
                input.removeTap(onBus: self.tapBusNumber)
                self.hasTapInstalled = false
            }

            // Get input format
            inputFormat = input.outputFormat(forBus: self.tapBusNumber)

            guard let format = inputFormat, format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioEngineRecorderError.invalidInputFormat
            }

            // Install tap for recording (this triggers mic indicator)
            input.installTap(onBus: self.tapBusNumber, bufferSize: self.tapBufferSize, format: format) { [weak self] (buffer, _) in
                guard let self = self else { return }
                self.audioProcessingQueue.async {
                    self.processAudioBuffer(buffer)
                }
            }
            self.hasTapInstalled = true

            // Restart engine with input tap
            engine.prepare()
            do {
                try engine.start()
                self.isEngineRunning = true
            } catch {
                // Clean up on failure
                input.removeTap(onBus: self.tapBusNumber)
                self.hasTapInstalled = false
                throw AudioEngineRecorderError.failedToStartEngine(error)
            }
        }

        guard let format = inputFormat else {
            throw AudioEngineRecorderError.invalidInputFormat
        }

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("Failed to create desired recording format")
            throw AudioEngineRecorderError.invalidRecordingFormat
        }

        recordingURL = url

        let createdAudioFile: AVAudioFile
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            createdAudioFile = try AVAudioFile(
                forWriting: url,
                settings: desiredFormat.settings,
                commonFormat: desiredFormat.commonFormat,
                interleaved: desiredFormat.isInterleaved
            )
        } catch {
            logger.error("Failed to create audio file: \(error.localizedDescription)")
            throw AudioEngineRecorderError.failedToCreateFile(error)
        }

        guard let audioConverter = AVAudioConverter(from: format, to: desiredFormat) else {
            logger.error("Failed to create audio format converter")
            throw AudioEngineRecorderError.failedToCreateConverter
        }

        // Atomically enable recording (buffer processing will start writing to file)
        fileWriteLock.lock()
        recordingFormat = desiredFormat
        audioFile = createdAudioFile
        converter = audioConverter
        _isRecording = true
        fileWriteLock.unlock()

        let elapsed = (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        logger.info("⏱️ Recording started in \(elapsed)ms (output-first warmup)")

        // Start validation timer
        startValidationTimer(url: url, retryCount: retryCount)
    }

    private func startValidationTimer(url: URL, retryCount: Int) {
        validationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            // Read hasReceivedValidBuffer under lock to avoid data race
            self.fileWriteLock.lock()
            let validationPassed = self.hasReceivedValidBuffer
            let stillRecording = self._isRecording
            self.fileWriteLock.unlock()

            // Don't retry if recording was stopped by user
            guard stillRecording else { return }

            if !validationPassed {
                self.logger.warning("Recording validation failed - no valid audio received")
                self.stopRecording()

                if retryCount < 2 {
                    self.logger.info("Retrying recording (attempt \(retryCount + 1)/2)...")
                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        do {
                            try self.startRecording(toOutputFile: url, retryCount: retryCount + 1)
                        } catch {
                            self.logger.error("Retry failed: \(error.localizedDescription)")
                            self.onRecordingError?(error)
                        }
                    }
                    self.retryWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
                } else {
                    self.logger.error("Recording failed after 2 retry attempts")
                    self.onRecordingError?(AudioEngineRecorderError.recordingValidationFailed)
                }
            } else {
                self.logger.info("✅ Recording validation passed")
            }
        }
    }

    func stopRecording() {
        // Cancel any pending validation/retry
        validationTimer?.invalidate()
        validationTimer = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil

        // Step 1: Atomically disable recording flag
        fileWriteLock.lock()
        let wasRecording = _isRecording
        _isRecording = false
        hasReceivedValidBuffer = false
        fileWriteLock.unlock()

        guard wasRecording else { return }

        // Step 2: Wait for any in-flight buffer processing to complete
        audioProcessingQueue.sync { }

        // Step 3: Clean up file resources
        fileWriteLock.lock()
        audioFile = nil
        converter = nil
        recordingFormat = nil
        fileWriteLock.unlock()

        recordingURL = nil

        // Step 4: Reset engine to clear microphone indicator
        // Once inputNode is accessed, the engine instance is "tainted" and keeps
        // the mic indicator active even after removing the tap. We must destroy
        // the engine and recreate it in output-only mode.
        engineQueue.async { [weak self] in
            guard let self = self else { return }

            // Remove tap first
            if self.hasTapInstalled {
                self.inputNode?.removeTap(onBus: self.tapBusNumber)
                self.hasTapInstalled = false
                self.inputNode = nil
            }

            // Stop and destroy the tainted engine to release mic hardware
            if self.isEngineRunning {
                self.audioEngine?.stop()
                self.isEngineRunning = false
            }
            self.audioEngine = nil

            // Recreate a clean output-only engine (maintains warmup, no mic indicator)
            self.prepareEngineSync()
        }

        Task { @MainActor [weak self] in
            self?.currentAveragePower = -160.0
            self?.currentPeakPower = -160.0
        }

        logger.info("✅ Recording stopped (engine reset, mic indicator cleared)")
    }

    /// Shutdown the engine completely (call during app termination)
    func shutdown() {
        validationTimer?.invalidate()
        validationTimer = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil

        engineQueue.sync { [weak self] in
            guard let self = self else { return }

            if let observer = self.configurationObserver {
                NotificationCenter.default.removeObserver(observer)
            }

            if self.hasTapInstalled {
                self.inputNode?.removeTap(onBus: self.tapBusNumber)
                self.hasTapInstalled = false
            }
            self.audioEngine?.stop()
            self.audioEngine = nil
            self.isEngineRunning = false

            self.logger.info("🛑 Audio engine shut down")
        }

        Task { @MainActor in
            self.isPrepared = false
        }
    }

    nonisolated private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Check recording flag under lock to avoid data race
        fileWriteLock.lock()
        let isRecording = _isRecording
        fileWriteLock.unlock()

        guard isRecording else { return }

        updateMeters(from: buffer)
        writeBufferToFile(buffer)
    }

    nonisolated private func writeBufferToFile(_ buffer: AVAudioPCMBuffer) {
        fileWriteLock.lock()
        defer { fileWriteLock.unlock() }

        guard _isRecording,
              let audioFile = audioFile,
              let converter = converter,
              let format = recordingFormat else { return }

        guard buffer.frameLength > 0 else {
            logTapError(message: "Empty buffer received")
            return
        }

        // Check format compatibility
        let bufferFormat = buffer.format
        let converterInputFormat = converter.inputFormat

        if bufferFormat.sampleRate != converterInputFormat.sampleRate ||
           bufferFormat.channelCount != converterInputFormat.channelCount {
            logTapError(message: "Format mismatch - buffer: \(bufferFormat.sampleRate)Hz/\(bufferFormat.channelCount)ch, converter expects: \(converterInputFormat.sampleRate)Hz/\(converterInputFormat.channelCount)ch")
            return
        }

        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = format.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            logTapError(message: "Failed to create converted buffer")
            return
        }

        var error: NSError?
        var hasProvidedBuffer = false

        converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            if hasProvidedBuffer {
                outStatus.pointee = .noDataNow
                return nil
            } else {
                hasProvidedBuffer = true
                outStatus.pointee = .haveData
                return buffer
            }
        }

        if let error = error {
            logTapError(message: "Audio conversion failed: \(error.localizedDescription)")
            return
        }

        if convertedBuffer.frameLength == 0 {
            logTapError(message: "Conversion produced 0 frames")
            return
        }

        do {
            try audioFile.write(from: convertedBuffer)
            // Mark that we've received valid data
            if !hasReceivedValidBuffer {
                hasReceivedValidBuffer = true
            }
        } catch {
            logTapError(message: "File write failed: \(error.localizedDescription)")
        }
    }

    nonisolated private func logTapError(message: String) {
        logger.error("\(message)")
    }

    nonisolated private func updateMeters(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        guard channelCount > 0, frameLength > 0 else { return }

        let channel = channelData[0]
        var sum: Float = 0.0
        var peak: Float = 0.0

        for frame in 0..<frameLength {
            let sample = channel[frame]
            let absSample = abs(sample)

            if absSample > peak {
                peak = absSample
            }

            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))

        let averagePowerDb = 20.0 * log10(max(rms, 0.000001))
        let peakPowerDb = 20.0 * log10(max(peak, 0.000001))

        Task { @MainActor in
            self.currentAveragePower = averagePowerDb
            self.currentPeakPower = peakPowerDb
        }
    }

    var isCurrentlyRecording: Bool {
        fileWriteLock.lock()
        defer { fileWriteLock.unlock() }
        return _isRecording
    }
    var currentRecordingURL: URL? { recordingURL }
}

// MARK: - Error Types

enum AudioEngineRecorderError: LocalizedError {
    case invalidInputFormat
    case invalidRecordingFormat
    case failedToCreateFile(Error)
    case failedToCreateConverter
    case failedToStartEngine(Error)
    case bufferConversionFailed
    case audioConversionError(Error)
    case fileWriteFailed(Error)
    case recordingValidationFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Invalid audio input format from device"
        case .invalidRecordingFormat:
            return "Failed to create recording format"
        case .failedToCreateFile(let error):
            return "Failed to create audio file: \(error.localizedDescription)"
        case .failedToCreateConverter:
            return "Failed to create audio format converter"
        case .failedToStartEngine(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .bufferConversionFailed:
            return "Failed to create buffer for audio conversion"
        case .audioConversionError(let error):
            return "Audio format conversion failed: \(error.localizedDescription)"
        case .fileWriteFailed(let error):
            return "Failed to write audio data to file: \(error.localizedDescription)"
        case .recordingValidationFailed:
            return "Recording failed to start - no valid audio received from device"
        }
    }
}
