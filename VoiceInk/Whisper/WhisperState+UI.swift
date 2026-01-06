import Foundation
import SwiftUI
import os

// MARK: - UI Management Extension
extension WhisperState {
    
    // MARK: - Recorder Panel Management
    
    func showRecorderPanel() {
        logger.notice("📱 Showing \(self.recorderType) recorder")
        if recorderType == "notch" {
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(whisperState: self, recorder: recorder)
            }
            notchWindowManager?.show()
        } else {
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(whisperState: self, recorder: recorder)
            }
            miniWindowManager?.show()
        }
    }
    
    func hideRecorderPanel() {
        if recorderType == "notch" {
            notchWindowManager?.hide()
        } else {
            miniWindowManager?.hide()
        }
    }
    
    // MARK: - Mini Recorder Management
    
    func toggleMiniRecorder(powerModeId: UUID? = nil) async {
        if isMiniRecorderVisible {
            if recordingState == .recording {
                await toggleRecord(powerModeId: powerModeId)
            } else {
                await cancelRecording()
            }
        } else {
            // Play sound (returns immediately, plays in background)
            SoundManager.shared.playStartSound()

            // Start recording engine in parallel with UI - don't await yet
            // This allows engine initialization to overlap with UI animation
            async let recordingStarted: () = toggleRecord(powerModeId: powerModeId)

            // Show UI concurrently while recording engine is starting
            await MainActor.run {
                isMiniRecorderVisible = true // This will call showRecorderPanel() via didSet
            }

            // Wait for recording to finish starting
            await recordingStarted
        }
    }
    
    func dismissMiniRecorder() async {
        if recordingState == .busy { return }

        let wasRecording = recordingState == .recording
 
        await MainActor.run {
            self.recordingState = .busy
        }
        
        if wasRecording {
            await recorder.stopRecording()
        }
        
        hideRecorderPanel()
        
        // Clear captured context when the recorder is dismissed
        if let enhancementService = enhancementService {
            await MainActor.run {
                enhancementService.clearCapturedContexts()
            }
        }
        
        await MainActor.run {
            isMiniRecorderVisible = false
        }
        
        await cleanupModelResources()
        
        if UserDefaults.standard.bool(forKey: PowerModeDefaults.autoRestoreKey) {
            await PowerModeSessionManager.shared.endSession()
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(nil)
            }
        }
        
        await MainActor.run {
            recordingState = .idle
        }
    }
    
    func resetOnLaunch() async {
        logger.notice("🔄 Resetting recording state on launch")
        await recorder.stopRecording()
        hideRecorderPanel()
        await MainActor.run {
            isMiniRecorderVisible = false
            shouldCancelRecording = false
            miniRecorderError = nil
            recordingState = .idle
        }
        await cleanupModelResources()
    }
    
    func cancelRecording() async {
        SoundManager.shared.playEscSound()
        shouldCancelRecording = true
        await dismissMiniRecorder()
    }
    
    // MARK: - Notification Handling
    
    func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleToggleMiniRecorder), name: .toggleMiniRecorder, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDismissMiniRecorder), name: .dismissMiniRecorder, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleLicenseStatusChanged), name: .licenseStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handlePromptChange), name: .promptDidChange, object: nil)
#if DEBUG
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleToggleMiniRecorder),
            name: Notification.Name("com.prakashjoshipax.VoiceInk.toggleMiniRecorder"),
            object: nil
        )
#endif
    }
    
    @objc public func handleToggleMiniRecorder() {
        Task {
            await toggleMiniRecorder()
        }
    }
    
    @objc public func handleDismissMiniRecorder() {
        Task {
            await dismissMiniRecorder()
        }
    }
    
    @objc func handleLicenseStatusChanged() {
        self.licenseViewModel = LicenseViewModel()
    }
    
    @objc func handlePromptChange() {
        // Update the whisper context with the new prompt
        Task {
            await updateContextPrompt()
        }
    }
    
    private func updateContextPrompt() async {
        // Always reload the prompt from UserDefaults to ensure we have the latest
        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? whisperPrompt.transcriptionPrompt
        
        if let context = whisperContext {
            await context.setPrompt(currentPrompt)
        }
    }
} 
