import Foundation
import os

/// Logs VoiceInk agent sessions to Obsidian vault as Markdown
actor ObsidianLogger {
    static let shared = ObsidianLogger()

    private let logger = Logger(subsystem: "com.prakashjoshipax.VoiceInk", category: "ObsidianLogger")

    /// User-configurable vault path (stored in UserDefaults)
    private let vaultPathKey = "voiceink_obsidian_vault_path"
    private let loggingEnabledKey = "voiceink_obsidian_logging_enabled"

    private var vaultPath: String? {
        UserDefaults.standard.string(forKey: vaultPathKey)
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: loggingEnabledKey)
    }

    /// Configure the Obsidian vault path
    func setVaultPath(_ path: String?) {
        if let path = path {
            UserDefaults.standard.set(path, forKey: vaultPathKey)
            logger.notice("Set Obsidian vault path: \(path)")
        } else {
            UserDefaults.standard.removeObject(forKey: vaultPathKey)
        }
    }

    /// Enable or disable Obsidian logging
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: loggingEnabledKey)
        logger.notice("Obsidian logging \(enabled ? "enabled" : "disabled")")
    }

    /// Log an agent session to Obsidian
    func logSession(
        configName: String,
        transcription: String,
        windowContext: String?,
        screenshotPath: String?,
        sessionId: String?,
        workingDirectory: String
    ) {
        guard isEnabled, let vault = vaultPath else {
            logger.notice("Obsidian logging skipped (disabled or no vault path)")
            return
        }

        let logsDir = (vault as NSString).appendingPathComponent("VoiceInk Logs")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: Date())

        // Create logs directory if needed
        try? FileManager.default.createDirectory(
            atPath: logsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Daily log file
        let fileName = "VoiceInk \(dateString).md"
        let filePath = (logsDir as NSString).appendingPathComponent(fileName)

        // Build log entry
        var entry = """

        ---

        ## \(timeString) - \(configName)

        **Working Directory:** `\(workingDirectory)`

        ### Transcription

        \(transcription)

        """

        if let context = windowContext, !context.isEmpty {
            entry += """

            ### Window Context

            \(context)

            """
        }

        if let screenshot = screenshotPath {
            entry += """

            ### Screenshot

            ![[VoiceInk Screenshot \(dateString) \(timeString).png]]

            *Path: `\(screenshot)`*

            """

            // Copy screenshot to vault if it exists
            copyScreenshotToVault(from: screenshot, vault: vault, date: dateString, time: timeString)
        }

        if let sid = sessionId {
            entry += """

            ### Session

            - **Session ID:** `\(sid)`
            - **Resume:** `claude --resume \(sid)`

            """
        }

        // Append to file
        if FileManager.default.fileExists(atPath: filePath) {
            if let handle = FileHandle(forWritingAtPath: filePath) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            // Create new file with header
            let header = """
            # VoiceInk Log - \(dateString)

            Daily log of VoiceInk agent sessions.

            """
            try? (header + entry).write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        logger.notice("Logged session to Obsidian: \(fileName)")
    }

    private func copyScreenshotToVault(from sourcePath: String, vault: String, date: String, time: String) {
        let attachmentsDir = (vault as NSString).appendingPathComponent("VoiceInk Logs/attachments")
        try? FileManager.default.createDirectory(
            atPath: attachmentsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let destName = "VoiceInk Screenshot \(date) \(time).png"
        let destPath = (attachmentsDir as NSString).appendingPathComponent(destName)

        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)
            logger.notice("Copied screenshot to vault: \(destName)")
        } catch {
            logger.error("Failed to copy screenshot: \(error.localizedDescription)")
        }
    }
}
