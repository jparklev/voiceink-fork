import Foundation
import os

/// Manages agent session persistence for auto-resume functionality
actor AgentSessionManager {
    static let shared = AgentSessionManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.VoiceInk", category: "AgentSessionManager")

    /// How long a session stays "resumable" (default: 30 minutes)
    private let sessionTimeoutSeconds: TimeInterval = 30 * 60

    private struct SessionRecord: Codable {
        let sessionId: String
        let configName: String
        let timestamp: Date
        let workingDirectory: String
    }

    private let storageKey = "voiceink_agent_sessions"

    /// Retrieve a resumable session for the given config, if one exists and is recent
    func getResumableSession(for config: CommandConfig) -> String? {
        let configName = config.name
        let workDir = config.workingDirectory
        logger.warning("LOOKUP session for config: '\(configName, privacy: .public)' workDir: '\(workDir, privacy: .public)'")

        let allRecords = loadAllRecords()
        logger.warning("Available keys: \(allRecords.keys.sorted().joined(separator: ", "), privacy: .public)")

        guard let record = allRecords[configName] else {
            logger.warning("No record found for '\(configName, privacy: .public)' in \(allRecords.count) records")
            return nil
        }

        let age = Date().timeIntervalSince(record.timestamp)
        let timeout = sessionTimeoutSeconds
        if age > timeout {
            logger.notice("Session expired for \(config.name): \(Int(age))s old (max \(Int(timeout))s)")
            clearSession(for: config.name)
            return nil
        }

        // Also check if working directory matches
        if record.workingDirectory != config.workingDirectory {
            logger.notice("Working directory changed for \(config.name), not resuming")
            clearSession(for: config.name)
            return nil
        }

        logger.notice("Found resumable session for \(config.name): \(record.sessionId) (\(Int(age))s old)")
        return record.sessionId
    }

    /// Store a session ID for future resumption
    func storeSession(sessionId: String, for config: CommandConfig) {
        let configName = config.name
        let workDir = config.workingDirectory
        logger.warning("STORE session for config: '\(configName, privacy: .public)' workDir: '\(workDir, privacy: .public)' sessionId: \(sessionId, privacy: .public)")

        let record = SessionRecord(
            sessionId: sessionId,
            configName: config.name,
            timestamp: Date(),
            workingDirectory: config.workingDirectory
        )

        var allRecords = loadAllRecords()
        allRecords[config.name] = record
        saveAllRecords(allRecords)

        logger.notice("Stored session for '\(config.name)': \(sessionId)")

        // Verify it was stored correctly
        let key = storageKey
        if let verifyData = UserDefaults.standard.data(forKey: key) {
            logger.notice("Verified: UserDefaults contains \(verifyData.count) bytes")
        } else {
            logger.error("Verification failed: UserDefaults data is nil after save!")
        }
    }

    /// Clear a specific session
    func clearSession(for configName: String) {
        var allRecords = loadAllRecords()
        allRecords.removeValue(forKey: configName)
        saveAllRecords(allRecords)
        logger.notice("Cleared session for \(configName)")
    }

    /// Clear all sessions (e.g., on app quit or user request)
    func clearAllSessions() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        logger.notice("Cleared all agent sessions")
    }

    /// Clean up expired sessions (call on app launch)
    func cleanupExpiredSessions() {
        var allRecords = loadAllRecords()
        let now = Date()
        var removed = 0

        for (name, record) in allRecords {
            if now.timeIntervalSince(record.timestamp) > sessionTimeoutSeconds {
                allRecords.removeValue(forKey: name)
                removed += 1
            }
        }

        if removed > 0 {
            saveAllRecords(allRecords)
            logger.notice("Cleaned up \(removed) expired session(s)")
        }
    }

    // MARK: - Private Helpers

    private func loadSession(for configName: String) -> SessionRecord? {
        loadAllRecords()[configName]
    }

    private func loadAllRecords() -> [String: SessionRecord] {
        let key = storageKey
        guard let data = UserDefaults.standard.data(forKey: key) else {
            logger.notice("No session data found in UserDefaults (key: \(key))")
            return [:]
        }

        do {
            let records = try JSONDecoder().decode([String: SessionRecord].self, from: data)
            logger.notice("Loaded \(records.count) session record(s): \(records.keys.joined(separator: ", "))")
            return records
        } catch {
            logger.error("Failed to decode session records: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveAllRecords(_ records: [String: SessionRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
            UserDefaults.standard.synchronize()  // Force immediate write
            logger.notice("Saved \(records.count) session record(s) to UserDefaults")
        } else {
            logger.error("Failed to encode session records")
        }
    }
}
