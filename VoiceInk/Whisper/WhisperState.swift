import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import KeyboardShortcuts
import os

// MARK: - Recording State Machine
enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case enhancing
    case busy
}

@MainActor
class WhisperState: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var isModelLoaded = false
    @Published var loadedLocalModel: WhisperModel?
    @Published var currentTranscriptionModel: (any TranscriptionModel)?
    @Published var isModelLoading = false
    @Published var availableModels: [WhisperModel] = []
    @Published var allAvailableModels: [any TranscriptionModel] = PredefinedModels.models
    @Published var clipboardMessage = ""
    @Published var miniRecorderError: String?
    @Published var shouldCancelRecording = false


    @Published var recorderType: String = UserDefaults.standard.string(forKey: "RecorderType") ?? "mini" {
        didSet {
            if isMiniRecorderVisible {
                if oldValue == "notch" {
                    notchWindowManager?.hide()
                    notchWindowManager = nil
                } else {
                    miniWindowManager?.hide()
                    miniWindowManager = nil
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    showRecorderPanel()
                }
            }
            UserDefaults.standard.set(recorderType, forKey: "RecorderType")
        }
    }
    
    @Published var isMiniRecorderVisible = false {
        didSet {
            if isMiniRecorderVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }
    
    var whisperContext: WhisperContext?
    let recorder = Recorder()
    var recordedFile: URL? = nil
    let whisperPrompt = WhisperPrompt()
    
    // Prompt detection service for trigger word handling
    private let promptDetectionService = PromptDetectionService()
    
    let modelContext: ModelContext
    
    internal var serviceRegistry: TranscriptionServiceRegistry!
    
    private var modelUrl: URL? {
        let possibleURLs = [
            Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin", subdirectory: "Models"),
            Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin"),
            Bundle.main.bundleURL.appendingPathComponent("Models/ggml-base.en.bin")
        ]
        
        for url in possibleURLs {
            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    
    private enum LoadError: Error {
        case couldNotLocateModel
    }
    
    let modelsDirectory: URL
    let recordingsDirectory: URL
    let enhancementService: AIEnhancementService?
    var licenseViewModel: LicenseViewModel
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperState")
    var notchWindowManager: NotchWindowManager?
    var miniWindowManager: MiniWindowManager?
    
    // For model progress tracking
    @Published var downloadProgress: [String: Double] = [:]
    @Published var parakeetDownloadStates: [String: Bool] = [:]
    
    init(modelContext: ModelContext, enhancementService: AIEnhancementService? = nil) {
        self.modelContext = modelContext
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        
        self.modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")
        
        self.enhancementService = enhancementService
        self.licenseViewModel = LicenseViewModel()
        
        super.init()
        
        // Configure the session manager
        if let enhancementService = enhancementService {
            PowerModeSessionManager.shared.configure(whisperState: self, enhancementService: enhancementService)
        }

        // Initialize the transcription service registry
        self.serviceRegistry = TranscriptionServiceRegistry(whisperState: self, modelsDirectory: self.modelsDirectory)
        
        setupNotifications()
        createModelsDirectoryIfNeeded()
        createRecordingsDirectoryIfNeeded()
        loadAvailableModels()
        loadCurrentTranscriptionModel()
        refreshAllAvailableModels()
        cleanupOldVoiceInkTempFiles()

        // Clean up expired agent sessions on launch
        Task {
            await AgentSessionManager.shared.cleanupExpiredSessions()
        }
    }

    // MARK: - Temp File Cleanup
    private func cleanupOldVoiceInkTempFiles(olderThan seconds: TimeInterval = 60 * 60 * 24) {
        let tmp = FileManager.default.temporaryDirectory
        let prefixes = ["voiceink_agent_prompt_", "voiceink_ghostty_"]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-seconds)

        for url in urls {
            let name = url.lastPathComponent
            guard prefixes.contains(where: name.hasPrefix) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let m = values?.contentModificationDate, m < cutoff {
                try? FileManager.default.removeItem(at: url)
                logger.notice("Cleaned up old temp file: \(name)")
            }
        }
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("Error creating recordings directory: \(error.localizedDescription)")
        }
    }
    
    func toggleRecord(powerModeId: UUID? = nil) async {
        if recordingState == .recording {
            await recorder.stopRecording()
            if let recordedFile {
                if !shouldCancelRecording {
                    let audioAsset = AVURLAsset(url: recordedFile)
                    let duration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

                    let transcription = Transcription(
                        text: "",
                        duration: duration,
                        audioFileURL: recordedFile.absoluteString,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await transcribeAudio(on: transcription)
                } else {
                    await MainActor.run {
                        recordingState = .idle
                    }
                    await cleanupModelResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                await MainActor.run {
                    recordingState = .idle
                }
            }
        } else {
            guard currentTranscriptionModel != nil else {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: "No AI Model Selected",
                        type: .error
                    )
                }
                return
            }
            shouldCancelRecording = false
            requestRecordPermission { [self] granted in
                if granted {
                    Task {
                        do {
                            // --- Prepare permanent file URL ---
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            await MainActor.run {
                                self.recordingState = .recording
                            }

                            if let powerModeId = powerModeId {
                                // Save current active config ID before switching using restore token
                                let previousId = PowerModeManager.shared.currentActiveConfiguration?.id
                                self.configRestoreToken = ConfigRestoreToken(previousConfigId: previousId, hadOverride: true)
                                self.logger.notice("🔄 Saved config restore token, previous: \(String(describing: previousId))")

                                await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)
                            } else {
                                let hasActiveSession = await PowerModeSessionManager.shared.hasActiveSession
                                if !hasActiveSession {
                                    await ActiveWindowService.shared.applyConfiguration()
                                }
                            }


                            // Load model and capture context in background without blocking
                            Task.detached { [weak self] in
                                guard let self = self else { return }

                                // Only load model if it's a local model and not already loaded
                                if let model = await self.currentTranscriptionModel, model.provider == .local {
                                    if let localWhisperModel = await self.availableModels.first(where: { $0.name == model.name }),
                                       await self.whisperContext == nil {
                                        do {
                                            try await self.loadModel(localWhisperModel)
                                        } catch {
                                            await self.logger.error("❌ Model loading failed: \(error.localizedDescription)")
                                        }
                                    }
                                } else if let parakeetModel = await self.currentTranscriptionModel as? ParakeetModel {
                                    try? await self.serviceRegistry.parakeetTranscriptionService.loadModel(for: parakeetModel)
                                }

                                if let enhancementService = await self.enhancementService {
                                    await MainActor.run {
                                        enhancementService.captureClipboardContext()
                                    }
                                    await enhancementService.captureScreenContext()
                                }
                            }

                        } catch {
                            self.logger.error("❌ Failed to start recording: \(error.localizedDescription)")
                            await NotificationManager.shared.showNotification(title: "Recording failed to start", type: .error)
                            await self.dismissMiniRecorder()
                            // Do not remove the file on a failed start, to preserve all recordings.
                            self.recordedFile = nil
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                }
            }
        }
    }
    
    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }
    
    private func transcribeAudio(on transcription: Transcription) async {
        guard let urlString = transcription.audioFileURL, let url = URL(string: urlString) else {
            logger.error("❌ Invalid audio file URL in transcription object.")
            await MainActor.run {
                recordingState = .idle
            }
            transcription.text = "Transcription Failed: Invalid audio file URL"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            return
        }

        if shouldCancelRecording {
            await MainActor.run {
                recordingState = .idle
            }
            await cleanupModelResources()
            return
        }

        await MainActor.run {
            recordingState = .transcribing
        }

        // Play stop sound when transcription starts with a small delay
        Task {
            let isSystemMuteEnabled = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled")
            if isSystemMuteEnabled {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200 milliseconds delay
            }
            await MainActor.run {
                SoundManager.shared.playStopSound()
            }
        }

        defer {
            if shouldCancelRecording {
                Task {
                    await cleanupModelResources()
                }
            }
        }

        logger.notice("🔄 Starting transcription...")
        
        var finalPastedText: String?
        var promptDetectionResult: PromptDetectionService.PromptDetectionResult?

        do {
            guard let model = currentTranscriptionModel else {
                throw WhisperStateError.transcriptionFailed
            }

            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model)
            logger.notice("📝 Raw transcript: \(text, privacy: .public)")
            text = TranscriptionOutputFilter.filter(text)
            logger.notice("📝 Output filter result: \(text, privacy: .public)")
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            let powerModeManager = PowerModeManager.shared
            let activePowerModeConfig = powerModeManager.currentActiveConfiguration
            let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
            let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

            if await checkCancellationAndCleanup() { return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
                text = WhisperTextFormatter.format(text)
                logger.notice("📝 Formatted transcript: \(text, privacy: .public)")
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("📝 WordReplacement: \(text, privacy: .public)")

            let audioAsset = AVURLAsset(url: url)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0
            
            transcription.text = text
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = powerModeName
            transcription.powerModeEmoji = powerModeEmoji
            finalPastedText = text
            
            if let enhancementService = enhancementService, enhancementService.isConfigured {
                let detectionResult = await promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            if let enhancementService = enhancementService,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured {
                if await checkCancellationAndCleanup() { return }

                await MainActor.run { self.recordingState = .enhancing }
                let textForAI = promptDetectionResult?.processedText ?? text
                
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    logger.notice("📝 AI enhancement: \(enhancedText, privacy: .public)")
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    finalPastedText = enhancedText
                } catch {
                    transcription.enhancedText = "Enhancement failed: \(error)"
                  
                    if await checkCancellationAndCleanup() { return }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            transcription.text = "Transcription Failed: \(fullErrorText)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        // --- Finalize and save ---
        try? modelContext.save()
        
        if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        }

        if await checkCancellationAndCleanup() { return }

        if let textToPaste = finalPastedText, transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            let powerMode = PowerModeManager.shared
            // Check if configuration is enabled before using it
            let activeConfig = powerMode.currentActiveConfiguration
            let outputAction = (activeConfig?.isEnabled == true) ? (activeConfig?.outputAction ?? .paste) : .paste

            switch outputAction {
            case .paste:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    CursorPaster.pasteAtCursor(textToPaste + " ")
                }

            case .pasteAndSend:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    CursorPaster.pasteAtCursor(textToPaste + " ")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        CursorPaster.pressEnter()
                    }
                }

            case .command(let config):
                logger.notice("🎯 Output action: command (\(config.name))")
                let useScreenCapture = activeConfig?.useScreenCapture ?? false
                await executeCommandAction(config: config, transcriptionText: textToPaste, useScreenCapture: useScreenCapture)
            }

            // Legacy fallback: if isAutoSendEnabled is set but outputAction is .paste
            if case .paste = outputAction,
               let activeConfig = powerMode.currentActiveConfiguration,
               activeConfig.isAutoSendEnabled,
               activeConfig.isEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    CursorPaster.pressEnter()
                }
            }
        }

        if let result = promptDetectionResult,
           let enhancementService = enhancementService,
           result.shouldEnableAI {
            await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
        }

        await self.dismissMiniRecorder()

        shouldCancelRecording = false
    }

    // MARK: - Configuration Restore Token
    private struct ConfigRestoreToken {
        let previousConfigId: UUID?
        let hadOverride: Bool
    }
    private var configRestoreToken: ConfigRestoreToken?

    // MARK: - Shell Helpers
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func buildResolvedArgs(_ config: CommandConfig) -> [String] {
        var args = config.arguments
        if let model = config.model, !model.isEmpty {
            args += ["--model", model]
        }
        return args
    }

    private func executeCommandAction(config: CommandConfig, transcriptionText: String, useScreenCapture: Bool) async {
        logger.notice("🔄 executeCommandAction starting (agent mode)...")
        recordingState = .busy

        var inputText = transcriptionText

        // Inject Agent Prompt if available from bundle
        if let resourcePath = Bundle.main.path(forResource: "AgentPrompt", ofType: "md"),
           let promptContent = try? String(contentsOfFile: resourcePath) {
            inputText = promptContent + "\n\nUser Request:\n" + inputText
        }

        // Capture screen context if enabled
        var screenshotPath: String?
        var windowContext: String?
        if useScreenCapture {
            let result = await captureScreenContextWithDetails()
            if let url = result.screenshotURL {
                screenshotPath = url.path
                var contextLines = ["\n\n## Screen Context"]
                if let info = result.windowInfo {
                    contextLines.append("- App: \(info.appName)")
                    windowContext = "App: \(info.appName)"
                    if let title = info.windowTitle {
                        contextLines.append("- Window: \(title)")
                        windowContext = (windowContext ?? "") + ", Window: \(title)"
                    }
                }
                contextLines.append("- Screenshot: \(url.path)")
                contextLines.append("- To view: `open \"\(url.path)\"`")
                inputText += contextLines.joined(separator: "\n")
            }
        }

        // Check for resumable session
        // Disabled auto-resume in favor of interactive loop
        // let resumableSessionId = await AgentSessionManager.shared.getResumableSession(for: config)
        let resumableSessionId: String? = nil

        // Log to Obsidian before launching
        await ObsidianLogger.shared.logSession(
            configName: config.name,
            transcription: transcriptionText,
            windowContext: windowContext,
            screenshotPath: screenshotPath,
            sessionId: resumableSessionId,
            workingDirectory: config.workingDirectory
        )

        // Launch agent in Ghostty
        await launchAgentInGhostty(config: config, prompt: inputText, resumeSessionId: resumableSessionId)

        // Cleanup state
        recordingState = .idle
        await restoreConfigurationIfNeeded()
    }

    // MARK: - Screen Context Capture
    private struct ScreenCaptureResult {
        let screenshotURL: URL?
        let windowInfo: WindowInfo?
    }

    private func captureScreenContextWithDetails() async -> ScreenCaptureResult {
        let capturer = ScreenCaptureService()
        let windowInfo = await getActiveWindowInfo()
        let url = await capturer.captureActiveWindowToFile()
        if let url = url {
            logger.notice("📸 Screenshot captured: \(url.path)")
        }
        return ScreenCaptureResult(screenshotURL: url, windowInfo: windowInfo)
    }

    private struct WindowInfo {
        let appName: String
        let windowTitle: String?
    }

    private func getActiveWindowInfo() async -> WindowInfo? {
        // Try to get info from aerospace
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
        task.arguments = ["list-windows", "--focused", "--json"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first,
               let appName = first["app-name"] as? String {
                let title = first["title"] as? String
                return WindowInfo(appName: appName, windowTitle: title)
            }
        } catch {
            logger.notice("Could not get window info from aerospace: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Ghostty Launch
    private func launchAgentInGhostty(config: CommandConfig, prompt: String, resumeSessionId: String?) async {
        // Write prompt to temp file
        let promptFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceink_agent_prompt_\(UUID().uuidString).txt")

        do {
            try prompt.write(to: promptFileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write prompt file: \(error)")
            await InsightPanelController.shared.showError("Failed to write prompt: \(error.localizedDescription)")
            return
        }

        // Check prompt size for ARG_MAX safety
        let promptSize = (try? FileManager.default.attributesOfItem(atPath: promptFileURL.path)[.size] as? Int) ?? 0
        if promptSize > 200_000 {
            logger.warning("Prompt size \(promptSize) bytes exceeds safe limit for argv")
        }

        guard let ghosttyAppUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty"),
              let bundle = Bundle(url: ghosttyAppUrl),
              let executableURL = bundle.executableURL else {
            logger.error("Ghostty not found")
            await InsightPanelController.shared.showError("Ghostty not installed")
            return
        }

        // Build the shell command with proper escaping
        let wdEsc = shellEscape(config.workingDirectory)
        let exeEsc = shellEscape(config.executable)
        let promptPathEsc = shellEscape(promptFileURL.path)
        let baseName = shellEscape((config.executable as NSString).lastPathComponent)

        // Build resolved arguments (includes --model if specified)
        var resolvedArgs = buildResolvedArgs(config)

        // Generate a new session ID for Claude to ensure we control sessions
        let newSessionId = UUID().uuidString.lowercased()

        // For Claude, add --session-id to control session explicitly
        let isClaude = config.executable.contains("claude") || config.name.lowercased().contains("claude")
        if isClaude && resumeSessionId == nil {
            resolvedArgs += ["--session-id", newSessionId]
        }

        let resolvedArgsEsc = resolvedArgs.map(shellEscape).joined(separator: " ")

        // Extract just the user's request (after "User Request:\n" if present) for display
        let userRequest: String
        if let range = prompt.range(of: "User Request:\n") {
            userRequest = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            userRequest = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Truncate for display (first 500 chars)
        let displayPrompt = userRequest.count > 500 ? String(userRequest.prefix(500)) + "..." : userRequest

        // Build the command string
        var bashCommand: String

        if let sessionId = resumeSessionId, let resumeSpec = config.resumeSpec {
            // Resume existing session
            let resumeArgs = resumeSpec.buildArguments(sessionId: sessionId).map(shellEscape).joined(separator: " ")
            let resumeExeEsc = shellEscape(resumeSpec.executable)

            bashCommand = """
            set -e
            cd \(wdEsc) || exit 1

            EXE=\(resumeExeEsc)
            if [ ! -x "$EXE" ]; then
                base=\(shellEscape((resumeSpec.executable as NSString).lastPathComponent))
                EXE="$(command -v "$base" 2>/dev/null || true)"
            fi

            if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
                echo "❌ Could not find executable for resume"
                read -p "Press Enter to close..."
                exit 1
            fi

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🔄 Resuming session: \(sessionId)"
            echo "📂 Working Directory: $(pwd)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            "$EXE" \(resumeArgs)

            echo ""
            echo "✅ Session ended."
            read -p "Press Enter to close..."
            """

            logger.notice("🔄 Resuming session \(sessionId) for \(config.name)")

            // Update the stored session timestamp
            await AgentSessionManager.shared.storeSession(sessionId: sessionId, for: config)
        } else {
            // New session - show the user's prompt
            let promptDisplay = displayPrompt.replacingOccurrences(of: "'", with: "'\\''")

            bashCommand = """
            set -e
            cd \(wdEsc) || exit 1

            EXE=\(exeEsc)
            if [ ! -x "$EXE" ]; then
                base=\(baseName)
                EXE="$(command -v "$base" 2>/dev/null || true)"
            fi

            if [ -z "$EXE" ] || [ ! -x "$EXE" ]; then
                echo "❌ Could not find executable: \(config.executable)"
                read -p "Press Enter to close..."
                exit 1
            fi
            
            SESSION_ID="\(newSessionId)"
            FIRST_RUN=true
            
            while true; do
                if [ "$FIRST_RUN" = "true" ]; then
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "🎤 Your request:"
                    echo '\(promptDisplay)'
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "📂 Working Directory: $(pwd)"
                    echo "🆔 Session ID: $SESSION_ID"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo ""

                    size=$(wc -c < \(promptPathEsc) | tr -d ' ')
                    if [ "$size" -gt 200000 ]; then
                        echo "⚠️ Prompt too large ($size bytes), opening in editor"
                        ${EDITOR:-vi} \(promptPathEsc)
                    else
                        "$EXE" \(resolvedArgsEsc) "$(cat \(promptPathEsc))"
                    fi
                    FIRST_RUN=false
                else
                    echo ""
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "🔄 Resuming session: $SESSION_ID"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    "$EXE" --resume "$SESSION_ID"
                fi

                echo ""
                echo "Session ended."
                # Read single character, silent, prompt user
                read -n 1 -p "Press Enter to close, or 'c' to continue session... " key
                echo ""
                
                # Check for 'c' or 'C'
                if [[ "$key" != "c" && "$key" != "C" ]]; then
                    break
                fi
            done
            """

            logger.notice("🚀 Starting new session \(newSessionId) for \(config.name)")

            // Store the session ID for future resume (optional, but good for history)
            if isClaude {
                await AgentSessionManager.shared.storeSession(sessionId: newSessionId, for: config)
            }
        }

        // Create Ghostty config
        let ghosttyConfigURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceink_ghostty_\(UUID().uuidString).config")
        let ghosttyConfig = """
        window-width = 120
        window-height = 40
        window-padding-x = 10
        window-padding-y = 10
        title = VoiceInk Agent - \(config.name)
        window-decoration = false
        """
        try? ghosttyConfig.write(to: ghosttyConfigURL, atomically: true, encoding: .utf8)

        // Launch Ghostty
        let task = Process()
        task.executableURL = executableURL
        task.arguments = [
            "--config-file=\(ghosttyConfigURL.path)",
            "-e", "bash", "-lc", bashCommand
        ]

        do {
            try task.run()
            logger.notice("🚀 Launched Ghostty for \(config.name)")
        } catch {
            logger.error("Failed to launch Ghostty: \(error)")
            await InsightPanelController.shared.showError("Failed to launch terminal: \(error.localizedDescription)")
        }
    }

    // MARK: - Configuration Restore
    private func restoreConfigurationIfNeeded() async {
        guard let token = configRestoreToken, token.hadOverride else { return }

        await MainActor.run {
            if let prevId = token.previousConfigId,
               let cfg = PowerModeManager.shared.getConfiguration(with: prevId) {
                PowerModeManager.shared.setActiveConfiguration(cfg)
                logger.notice("↩️ Restored previous configuration: \(cfg.name)")
            } else {
                PowerModeManager.shared.setActiveConfiguration(nil)
                logger.notice("↩️ Restored previous configuration: None (Default)")
            }
        }
        configRestoreToken = nil
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }
    
    private func checkCancellationAndCleanup() async -> Bool {
        if shouldCancelRecording {
            await cleanupModelResources()
            return true
        }
        return false
    }

    private func cleanupAndDismiss() async {
        await dismissMiniRecorder()
    }
}
