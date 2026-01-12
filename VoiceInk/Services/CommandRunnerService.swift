import Foundation
import os

actor CommandRunnerService {
    static let shared = CommandRunnerService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.VoiceInk", category: "CommandRunner")

    struct CommandResult {
        let output: String
        let exitCode: Int32
        let error: String?
    }

    enum CommandError: LocalizedError {
        case executableNotFound(String)
        case workingDirectoryNotFound(String)
        case timeout(TimeInterval)
        case processError(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let path):
                return "Executable not found: \(path)"
            case .workingDirectoryNotFound(let path):
                return "Working directory not found: \(path)"
            case .timeout(let seconds):
                return "Command timed out after \(Int(seconds)) seconds"
            case .processError(let message):
                return "Process error: \(message)"
            }
        }
    }

    func run(config: CommandConfig, transcriptionText: String, timeout: TimeInterval = 120) async throws -> CommandResult {
        let expandedExecutable = (config.executable as NSString).expandingTildeInPath
        let expandedWorkingDir = (config.workingDirectory as NSString).expandingTildeInPath

        logger.notice("🚀 CommandRunner starting: \(config.name)")
        logger.notice("   Executable: \(expandedExecutable)")
        logger.notice("   Working dir: \(expandedWorkingDir)")
        logger.notice("   Arguments: \(config.arguments.joined(separator: " "))")
        logger.notice("   Model: \(config.model ?? "default")")
        logger.notice("   Timeout: \(timeout)s")
        logger.notice("   Input text (\(transcriptionText.count) chars): \(transcriptionText.prefix(100))...")

        // Validate executable exists and is executable
        guard FileManager.default.isExecutableFile(atPath: expandedExecutable) else {
            logger.error("❌ Executable not found or not executable: \(expandedExecutable)")
            throw CommandError.executableNotFound(config.executable)
        }

        // Validate working directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedWorkingDir, isDirectory: &isDir), isDir.boolValue else {
            logger.error("❌ Working directory not found: \(expandedWorkingDir)")
            throw CommandError.workingDirectoryNotFound(config.workingDirectory)
        }

        logger.notice("✅ Paths validated, spawning process...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: expandedExecutable)

        // Build arguments
        var args = config.arguments
        if let model = config.model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        process.arguments = args

        // Set working directory
        process.currentDirectoryURL = URL(fileURLWithPath: expandedWorkingDir)

        // Inherit environment (important for PATH, API keys, etc.)
        process.environment = ProcessInfo.processInfo.environment

        // Set up pipes
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Run with timeout - ensure process is always terminated on timeout or error
        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            // Main execution task
            group.addTask {
                do {
                    try process.run()
                } catch {
                    throw CommandError.processError(error.localizedDescription)
                }

                // Write transcription to stdin and close
                if let transcriptionData = transcriptionText.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(transcriptionData)
                }
                inputPipe.fileHandleForWriting.closeFile()

                // Read output BEFORE waitUntilExit (prevents deadlock)
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                // Now wait for process to exit
                process.waitUntilExit()

                return CommandResult(
                    output: String(data: outputData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus,
                    error: String(data: errorData, encoding: .utf8)
                )
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CommandError.timeout(timeout)
            }

            // Return first result, cancel remaining - ALWAYS clean up process
            do {
                let result = try await group.next()!
                group.cancelAll()

                // Terminate process if still running (shouldn't happen on success, but be safe)
                if process.isRunning {
                    self.logger.warning("⏱️ Terminating still-running process")
                    process.terminate()
                }

                // Log result
                self.logger.notice("✅ Command completed with exit code: \(result.exitCode)")
                self.logger.notice("   Output length: \(result.output.count) chars")
                if let err = result.error, !err.isEmpty {
                    self.logger.notice("   Stderr: \(err.prefix(200))...")
                }
                self.logger.notice("   Output preview: \(result.output.prefix(200))...")

                return result
            } catch {
                // CRITICAL: Always terminate process on any error (including timeout)
                group.cancelAll()
                if process.isRunning {
                    self.logger.warning("⏱️ Terminating process due to error: \(error.localizedDescription)")
                    process.terminate()
                }
                throw error
            }
        }
    }
}
