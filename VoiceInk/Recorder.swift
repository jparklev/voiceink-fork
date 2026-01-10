import Foundation
import AVFoundation
import CoreAudio
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    // Output-first warmup: engine warms at init without mic tap, tap attaches on record
    private let recorder: AudioEngineRecorder
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceObserver: NSObjectProtocol?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    @Published var isEnginePrepared = false
    private var audioLevelCheckTask: Task<Void, Never>?
    private var audioMeterUpdateTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var hasDetectedAudioInCurrentSession = false
    private var currentRecordingURL: URL?

    enum RecorderError: Error {
        case couldNotStartRecording
    }

    override init() {
        // Create pre-warmed audio engine
        recorder = AudioEngineRecorder()
        super.init()

        // Set up engine restart handler for device changes during recording
        recorder.onEngineRestarted = { [weak self] in
            Task { @MainActor in
                await self?.handleEngineRestarted()
            }
        }

        // Warm the engine (output-only) - eliminates startup delay without mic indicator
        recorder.prepare()

        // Observe engine prepared state
        Task { @MainActor in
            for await isPrepared in self.recorder.$isPrepared.values {
                self.isEnginePrepared = isPrepared
            }
        }

        setupDeviceChangeObserver()
    }

    private func setupDeviceChangeObserver() {
        deviceObserver = AudioDeviceConfiguration.createDeviceChangeObserver { [weak self] in
            Task {
                await self?.handleDeviceChange()
            }
        }
    }

    private func handleDeviceChange() async {
        // With pre-warmed engine, device changes are handled by AVAudioEngineConfigurationChange
        // notification in AudioEngineRecorder. We only need to update the device manager state.
        guard !recorder.isCurrentlyRecording else { return }

        // If not recording, just log the change - engine will handle reconfiguration automatically
        logger.info("Device change detected (not recording) - engine will auto-reconfigure")
    }

    private func handleEngineRestarted() async {
        // Engine was reconfigured due to device change while recording
        // We do NOT try to resume recording to the same file because:
        // 1. AVAudioFile(forWriting:) would truncate/overwrite existing data
        // 2. The brief audio gap during device transition is acceptable
        // 3. The recorded file is preserved up to the device change point

        guard currentRecordingURL != nil else { return }

        logger.warning("⚠️ Audio device changed during recording - recording stopped to preserve data")

        // Stop recording cleanly to preserve what was recorded
        stopRecording()

        // Notify user
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: "Recording stopped - audio device changed",
                type: .warning
            )
        }

        // Post notification so UI can handle the interrupted recording
        // (e.g., toggle mini recorder off, trigger transcription of partial recording)
        await MainActor.run {
            NotificationCenter.default.post(name: .toggleMiniRecorder, object: nil)
        }
    }
    
    private func configureAudioSession(with deviceID: AudioDeviceID) async throws {
        if let currentDefault = AudioDeviceConfiguration.getDefaultInputDevice(),
           currentDefault == deviceID {
            return
        }
        try AudioDeviceConfiguration.setDefaultInputDevice(deviceID)
    }
    
    func startRecording(toOutputFile url: URL) async throws {
        let startTime = DispatchTime.now()
        deviceManager.isRecordingActive = true

        let currentDeviceID = deviceManager.getCurrentDevice()
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")

        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: "Using: \(deviceName)",
                        type: .info
                    )
                }
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        hasDetectedAudioInCurrentSession = false

        let deviceID = deviceManager.getCurrentDevice()
        let configStart = DispatchTime.now()
        do {
            try await configureAudioSession(with: deviceID)
            let configMs = (DispatchTime.now().uptimeNanoseconds - configStart.uptimeNanoseconds) / 1_000_000
            logger.info("⏱️ Audio session config \(configMs, privacy: .public)ms")
        } catch {
            logger.warning("⚠️ Failed to configure audio session for device \(deviceID), attempting to continue: \(error.localizedDescription)")
        }

        do {
            // Set up error callback to handle runtime recording failures
            recorder.onRecordingError = { [weak self] error in
                Task { @MainActor in
                    await self?.handleRecordingError(error)
                }
            }

            // Track current recording URL for device change recovery
            currentRecordingURL = url

            let engineStart = DispatchTime.now()
            try recorder.startRecording(toOutputFile: url)
            let engineMs = (DispatchTime.now().uptimeNanoseconds - engineStart.uptimeNanoseconds) / 1_000_000
            let totalMs = (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            logger.info("✅ Recording started (output-first warmup)")
            logger.info("⏱️ Recording start \(engineMs, privacy: .public)ms (total \(totalMs, privacy: .public)ms)")

            audioRestorationTask?.cancel()
            audioRestorationTask = nil

            Task { [weak self] in
                guard let self = self else { return }
                await self.playbackController.pauseMedia()
                _ = await self.mediaController.muteSystemAudio()
            }

            audioLevelCheckTask?.cancel()
            audioMeterUpdateTask?.cancel()

            audioMeterUpdateTask = Task { [weak self] in
                guard let self = self else { return }
                while self.recorder.isCurrentlyRecording && !Task.isCancelled {
                    self.updateAudioMeter()
                    try? await Task.sleep(nanoseconds: 17_000_000)
                }
            }

            audioLevelCheckTask = Task { [weak self] in
                guard let self = self else { return }
                let notificationChecks: [TimeInterval] = [5.0, 12.0]

                for delay in notificationChecks {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                    if Task.isCancelled { return }

                    if self.hasDetectedAudioInCurrentSession {
                        return
                    }

                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: "No Audio Detected",
                            type: .warning
                        )
                    }
                }
            }

        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }
    
    func stopRecording() {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        recorder.stopRecording()
        currentRecordingURL = nil
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error.localizedDescription)")

        // Stop the recording
        stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: "Recording Failed: \(error.localizedDescription)",
                type: .error
            )
        }
    }

    private func updateAudioMeter() {
        let averagePower = recorder.currentAveragePower
        let peakPower = recorder.currentPeakPower

        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let newAudioMeter = AudioMeter(averagePower: Double(normalizedAverage), peakPower: Double(normalizedPeak))

        if !hasDetectedAudioInCurrentSession && newAudioMeter.averagePower > 0.01 {
            hasDetectedAudioInCurrentSession = true
        }

        audioMeter = newAudioMeter
    }
    
    // MARK: - Cleanup

    deinit {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
