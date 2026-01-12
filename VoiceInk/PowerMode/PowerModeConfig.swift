import Foundation
import KeyboardShortcuts

// MARK: - Command Runner Types

/// How the command should be executed
enum CommandExecutionMode: String, Codable, Equatable {
    case silent              // Run in background, capture output (legacy, unused)
    case terminalInteractive // Launch in Ghostty terminal for interactive use
}

/// Configuration for resuming an agent session
struct ResumeSpec: Codable, Equatable {
    let executable: String
    let argumentsTemplate: [String]  // supports "{{sessionId}}" placeholder

    func buildArguments(sessionId: String) -> [String] {
        argumentsTemplate.map { $0.replacingOccurrences(of: "{{sessionId}}", with: sessionId) }
    }

    static func claude(executable: String) -> ResumeSpec {
        ResumeSpec(executable: executable, argumentsTemplate: ["--resume", "{{sessionId}}"])
    }

    static func gemini(executable: String) -> ResumeSpec {
        // Gemini CLI uses --session flag
        ResumeSpec(executable: executable, argumentsTemplate: ["--session", "{{sessionId}}"])
    }
}

struct CommandConfig: Codable, Equatable {
    let name: String
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let pasteOutput: Bool
    let model: String?
    let timeout: TimeInterval
    var executionMode: CommandExecutionMode
    var resumeSpec: ResumeSpec?

    enum CodingKeys: String, CodingKey {
        case name, executable, arguments, workingDirectory, pasteOutput, model, timeout
        case executionMode, resumeSpec
    }

    init(
        name: String,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String,
        pasteOutput: Bool = true,
        model: String? = nil,
        timeout: TimeInterval = 120,
        executionMode: CommandExecutionMode = .terminalInteractive,
        resumeSpec: ResumeSpec? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.pasteOutput = pasteOutput
        self.model = model
        self.timeout = timeout
        self.executionMode = executionMode
        self.resumeSpec = resumeSpec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decode([String].self, forKey: .arguments)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        pasteOutput = try c.decode(Bool.self, forKey: .pasteOutput)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        timeout = try c.decode(TimeInterval.self, forKey: .timeout)

        // Migration: if executionMode not present, always use terminalInteractive
        if let mode = try c.decodeIfPresent(CommandExecutionMode.self, forKey: .executionMode) {
            executionMode = mode
        } else {
            executionMode = .terminalInteractive
        }

        // Migration: if resumeSpec not present, auto-populate for known agents
        if let spec = try c.decodeIfPresent(ResumeSpec.self, forKey: .resumeSpec) {
            resumeSpec = spec
        } else {
            // Auto-detect based on executable or name
            let execName = (executable as NSString).lastPathComponent.lowercased()
            let nameLower = name.lowercased()

            if execName.contains("claude") || nameLower.contains("claude") {
                resumeSpec = .claude(executable: executable)
            } else if execName.contains("gemini") || nameLower.contains("gemini") {
                resumeSpec = .gemini(executable: executable)
            } else {
                resumeSpec = nil
            }
        }
    }

    /// Finds an executable in common locations, returning the first match
    private static func findExecutable(_ name: String, additionalPaths: [String] = []) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = additionalPaths + [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: let the shell find it via command -v
        return name
    }

    static func claudeAgent(
        workingDirectory: String,
        model: String = "opus"
    ) -> CommandConfig {
        let executable = findExecutable("claude")
        return CommandConfig(
            name: "Claude Agent",
            executable: executable,
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: workingDirectory,
            pasteOutput: false,
            model: model,
            timeout: 300,
            executionMode: .terminalInteractive,
            resumeSpec: .claude(executable: executable)
        )
    }

    static func geminiAgent(
        workingDirectory: String,
        model: String = "gemini-2.0-flash-exp"
    ) -> CommandConfig {
        let executable = findExecutable("gemini")
        return CommandConfig(
            name: "Gemini Agent",
            executable: executable,
            arguments: [],
            workingDirectory: workingDirectory,
            pasteOutput: false,
            model: model,
            timeout: 300,
            executionMode: .terminalInteractive,
            resumeSpec: .gemini(executable: executable)
        )
    }
}

enum OutputAction: Codable, Equatable {
    case paste
    case pasteAndSend
    case command(CommandConfig)

    private enum CodingKeys: String, CodingKey {
        case type
        case config
    }

    private enum ActionType: String, Codable {
        case paste
        case pasteAndSend
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .paste:
            self = .paste
        case .pasteAndSend:
            self = .pasteAndSend
        case .command:
            let config = try container.decode(CommandConfig.self, forKey: .config)
            self = .command(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .paste:
            try container.encode(ActionType.paste, forKey: .type)
        case .pasteAndSend:
            try container.encode(ActionType.pasteAndSend, forKey: .type)
        case .command(let config):
            try container.encode(ActionType.command, forKey: .type)
            try container.encode(config, forKey: .config)
        }
    }
}

// MARK: - PowerMode Configuration

struct PowerModeConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var appConfigs: [AppConfig]?
    var urlConfigs: [URLConfig]?
    var isAIEnhancementEnabled: Bool
    var selectedPrompt: String?
    var selectedTranscriptionModelName: String?
    var selectedLanguage: String?
    var useScreenCapture: Bool
    var selectedAIProvider: String?
    var selectedAIModel: String?
    var isAutoSendEnabled: Bool = false
    var isEnabled: Bool = true
    var isDefault: Bool = false
    var hotkeyShortcut: String? = nil
    var outputAction: OutputAction = .paste

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, appConfigs, urlConfigs, isAIEnhancementEnabled, selectedPrompt, selectedLanguage, useScreenCapture, selectedAIProvider, selectedAIModel, isAutoSendEnabled, isEnabled, isDefault, hotkeyShortcut, outputAction
        case selectedWhisperModel
        case selectedTranscriptionModelName
    }
    
    init(id: UUID = UUID(), name: String, emoji: String, appConfigs: [AppConfig]? = nil,
         urlConfigs: [URLConfig]? = nil, isAIEnhancementEnabled: Bool, selectedPrompt: String? = nil,
         selectedTranscriptionModelName: String? = nil, selectedLanguage: String? = nil, useScreenCapture: Bool = false,
         selectedAIProvider: String? = nil, selectedAIModel: String? = nil, isAutoSendEnabled: Bool = false, isEnabled: Bool = true, isDefault: Bool = false, hotkeyShortcut: String? = nil, outputAction: OutputAction = .paste) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.appConfigs = appConfigs
        self.urlConfigs = urlConfigs
        self.isAIEnhancementEnabled = isAIEnhancementEnabled
        self.selectedPrompt = selectedPrompt
        self.useScreenCapture = useScreenCapture
        self.isAutoSendEnabled = isAutoSendEnabled
        self.selectedAIProvider = selectedAIProvider ?? UserDefaults.standard.string(forKey: "selectedAIProvider")
        self.selectedAIModel = selectedAIModel
        self.selectedTranscriptionModelName = selectedTranscriptionModelName ?? UserDefaults.standard.string(forKey: "CurrentTranscriptionModel")
        self.selectedLanguage = selectedLanguage ?? UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.hotkeyShortcut = hotkeyShortcut
        self.outputAction = outputAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decode(String.self, forKey: .emoji)
        appConfigs = try container.decodeIfPresent([AppConfig].self, forKey: .appConfigs)
        urlConfigs = try container.decodeIfPresent([URLConfig].self, forKey: .urlConfigs)
        isAIEnhancementEnabled = try container.decode(Bool.self, forKey: .isAIEnhancementEnabled)
        selectedPrompt = try container.decodeIfPresent(String.self, forKey: .selectedPrompt)
        selectedLanguage = try container.decodeIfPresent(String.self, forKey: .selectedLanguage)
        useScreenCapture = try container.decode(Bool.self, forKey: .useScreenCapture)
        selectedAIProvider = try container.decodeIfPresent(String.self, forKey: .selectedAIProvider)
        selectedAIModel = try container.decodeIfPresent(String.self, forKey: .selectedAIModel)
        isAutoSendEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoSendEnabled) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        hotkeyShortcut = try container.decodeIfPresent(String.self, forKey: .hotkeyShortcut)
        outputAction = try container.decodeIfPresent(OutputAction.self, forKey: .outputAction) ?? .paste

        if let newModelName = try container.decodeIfPresent(String.self, forKey: .selectedTranscriptionModelName) {
            selectedTranscriptionModelName = newModelName
        } else if let oldModelName = try container.decodeIfPresent(String.self, forKey: .selectedWhisperModel) {
            selectedTranscriptionModelName = oldModelName
        } else {
            selectedTranscriptionModelName = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(emoji, forKey: .emoji)
        try container.encodeIfPresent(appConfigs, forKey: .appConfigs)
        try container.encodeIfPresent(urlConfigs, forKey: .urlConfigs)
        try container.encode(isAIEnhancementEnabled, forKey: .isAIEnhancementEnabled)
        try container.encodeIfPresent(selectedPrompt, forKey: .selectedPrompt)
        try container.encodeIfPresent(selectedLanguage, forKey: .selectedLanguage)
        try container.encode(useScreenCapture, forKey: .useScreenCapture)
        try container.encodeIfPresent(selectedAIProvider, forKey: .selectedAIProvider)
        try container.encodeIfPresent(selectedAIModel, forKey: .selectedAIModel)
        try container.encode(isAutoSendEnabled, forKey: .isAutoSendEnabled)
        try container.encodeIfPresent(selectedTranscriptionModelName, forKey: .selectedTranscriptionModelName)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(hotkeyShortcut, forKey: .hotkeyShortcut)
        try container.encode(outputAction, forKey: .outputAction)
    }


    static func == (lhs: PowerModeConfig, rhs: PowerModeConfig) -> Bool {
        lhs.id == rhs.id
    }
}

struct AppConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var bundleIdentifier: String
    var appName: String
    
    init(id: UUID = UUID(), bundleIdentifier: String, appName: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }
    
    static func == (lhs: AppConfig, rhs: AppConfig) -> Bool {
        lhs.id == rhs.id
    }
}

struct URLConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    
    init(id: UUID = UUID(), url: String) {
        self.id = id
        self.url = url
    }
    
    static func == (lhs: URLConfig, rhs: URLConfig) -> Bool {
        lhs.id == rhs.id
    }
}

class PowerModeManager: ObservableObject {
    static let shared = PowerModeManager()
    @Published var configurations: [PowerModeConfig] = []
    @Published var activeConfiguration: PowerModeConfig?

    private let configKey = "powerModeConfigurationsV2"
    private let activeConfigIdKey = "activeConfigurationId"

    private init() {
        loadConfigurations()

        if let activeConfigIdString = UserDefaults.standard.string(forKey: activeConfigIdKey),
           let activeConfigId = UUID(uuidString: activeConfigIdString) {
            activeConfiguration = configurations.first { $0.id == activeConfigId }
        } else {
            activeConfiguration = nil
        }
    }

    private func loadConfigurations() {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let configs = try? JSONDecoder().decode([PowerModeConfig].self, from: data) {
            configurations = configs
        }
    }

    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
        NotificationCenter.default.post(name: NSNotification.Name("PowerModeConfigurationsDidChange"), object: nil)
    }

    func addConfiguration(_ config: PowerModeConfig) {
        if !configurations.contains(where: { $0.id == config.id }) {
            configurations.append(config)
            saveConfigurations()
        }
    }

    func removeConfiguration(with id: UUID) {
        KeyboardShortcuts.setShortcut(nil, for: .powerMode(id: id))
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }

    func getConfiguration(with id: UUID) -> PowerModeConfig? {
        return configurations.first { $0.id == id }
    }

    func updateConfiguration(_ config: PowerModeConfig) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()
        }
    }

    func moveConfigurations(fromOffsets: IndexSet, toOffset: Int) {
        configurations.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveConfigurations()
    }

    func getConfigurationForURL(_ url: String) -> PowerModeConfig? {
        let cleanedURL = cleanURL(url)
        
        for config in configurations.filter({ $0.isEnabled }) {
            if let urlConfigs = config.urlConfigs {
                for urlConfig in urlConfigs {
                    let configURL = cleanURL(urlConfig.url)
                    
                    if cleanedURL.contains(configURL) {
                        return config
                    }
                }
            }
        }
        return nil
    }
    
    func getConfigurationForApp(_ bundleId: String) -> PowerModeConfig? {
        for config in configurations.filter({ $0.isEnabled }) {
            if let appConfigs = config.appConfigs {
                if appConfigs.contains(where: { $0.bundleIdentifier == bundleId }) {
                    return config
                }
            }
        }
        return nil
    }
    
    func getDefaultConfiguration() -> PowerModeConfig? {
        return configurations.first { $0.isEnabled && $0.isDefault }
    }
    
    func hasDefaultConfiguration() -> Bool {
        return configurations.contains { $0.isDefault }
    }
    
    func setAsDefault(configId: UUID, skipSave: Bool = false) {
        for index in configurations.indices {
            configurations[index].isDefault = false
        }

        if let index = configurations.firstIndex(where: { $0.id == configId }) {
            configurations[index].isDefault = true
        }

        if !skipSave {
            saveConfigurations()
        }
    }
    
    func enableConfiguration(with id: UUID) {
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = true
            saveConfigurations()
        }
    }
    
    func disableConfiguration(with id: UUID) {
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = false
            saveConfigurations()
        }
    }
    
    var enabledConfigurations: [PowerModeConfig] {
        return configurations.filter { $0.isEnabled }
    }

    func addAppConfig(_ appConfig: AppConfig, to config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.appConfigs ?? []
            configs.append(appConfig)
            updatedConfig.appConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeAppConfig(_ appConfig: AppConfig, from config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.appConfigs?.removeAll(where: { $0.id == appConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func addURLConfig(_ urlConfig: URLConfig, to config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.urlConfigs ?? []
            configs.append(urlConfig)
            updatedConfig.urlConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeURLConfig(_ urlConfig: URLConfig, from config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.urlConfigs?.removeAll(where: { $0.id == urlConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func cleanURL(_ url: String) -> String {
        return url.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setActiveConfiguration(_ config: PowerModeConfig?) {
        activeConfiguration = config
        UserDefaults.standard.set(config?.id.uuidString, forKey: activeConfigIdKey)
        self.objectWillChange.send()
    }

    var currentActiveConfiguration: PowerModeConfig? {
        return activeConfiguration
    }

    func getAllAvailableConfigurations() -> [PowerModeConfig] {
        return configurations
    }

    func isEmojiInUse(_ emoji: String) -> Bool {
        return configurations.contains { $0.emoji == emoji }
    }

    // MARK: - Silent Claude PowerMode

    func createGeminiAgentPowerMode() {
        // Check if already exists
        if configurations.contains(where: { $0.name == "Gemini Agent" }) {
            print("🤖 Gemini Agent PowerMode already exists")
            return
        }

        // Use home directory as default working directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        let geminiConfig = CommandConfig.geminiAgent(
            workingDirectory: homeDir,
            model: "gemini-2.0-flash-exp"
        )

        let geminiMode = PowerModeConfig(
            name: "Gemini Agent",
            emoji: "🤖",
            isAIEnhancementEnabled: false,
            useScreenCapture: false,
            isEnabled: true,
            outputAction: .command(geminiConfig)
        )

        addConfiguration(geminiMode)
        print("🤖 Created Gemini Agent PowerMode")
    }
} 