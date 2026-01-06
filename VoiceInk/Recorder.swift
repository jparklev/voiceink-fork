import Foundation
import AVFoundation
import CoreAudio
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: AudioEngineRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioLevelCheckTask: Task<Void, Never>?
    private var audioMeterUpdateTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var hasDetectedAudioInCurrentSession = false
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
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
        guard !isReconfiguring else { return }
        guard recorder?.isCurrentlyRecording == true else { return }
        
        isReconfiguring = true
        
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        await MainActor.run {
            NotificationCenter.default.post(name: .toggleMiniRecorder, object: nil)
        }
        
        isReconfiguring = false
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
            if recorder == nil {
                recorder = AudioEngineRecorder()
            }
            guard let engineRecorder = recorder else {
                throw RecorderError.couldNotStartRecording
            }

            // Set up error callback to handle runtime recording failures
            engineRecorder.onRecordingError = { [weak self] error in
                Task { @MainActor in
                    await self?.handleRecordingError(error)
                }
            }

            let engineStart = DispatchTime.now()
            try engineRecorder.startRecording(toOutputFile: url)
            let engineMs = (DispatchTime.now().uptimeNanoseconds - engineStart.uptimeNanoseconds) / 1_000_000
            let totalMs = (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            logger.info("✅ AudioEngineRecorder started successfully")
            logger.info("⏱️ Audio engine start \(engineMs, privacy: .public)ms (total \(totalMs, privacy: .public)ms)")

            audioRestorationTask?.cancel()
            audioRestorationTask = nil

            Task { [weak self] in
                guard let self = self else { return }
                await self.playbackController.pauseMedia()
                _ = await self.mediaController.muteSystemAudio()
            }

            audioLevelCheckTask?.cancel()
            audioMeterUpdateTask?.cancel()

            audioMeterUpdateTask = Task {
                while recorder?.isCurrentlyRecording == true && !Task.isCancelled {
                    updateAudioMeter()
                    try? await Task.sleep(nanoseconds: 17_000_000)
                }
            }

            audioLevelCheckTask = Task {
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
            logger.error("Failed to create audio recorder: \(error.localizedDescription)")
            stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }
    
    func stopRecording() {
        audioLevelCheckTask?.cancel()
        audioMeterUpdateTask?.cancel()
        recorder?.stopRecording()
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
        guard let recorder = recorder else { return }

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
