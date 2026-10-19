import Foundation

struct TranscriptionOutputFilter {
    private static let removePunctuationKey = "RemovePunctuation"
    private static let lowercaseTranscriptionKey = "LowercaseTranscription"
    private static let apostropheLikeCharacters = CharacterSet(charactersIn: "'’‘ʼ＇")
    
    // Non-speech tags Whisper emits, e.g. [BLANK_AUDIO], (upbeat music), [ Silence ]. Other bracketed text is speech.
    private static let nonSpeechTagPattern = #"[\[({]\s*(?:[\w-]+\s+){0,2}(?:blank_audio|music|applause|laugh\w*|silence|noise|inaudible|sound|static|clicking|typing|sighs?|coughs?|beeps?|crosstalk)\s*[\])}]"#

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        filteredText = filteredText.replacingOccurrences(of: nonSpeechTagPattern, with: "", options: [.regularExpression, .caseInsensitive])

        // Remove filler words (if enabled)
        if FillerWordManager.shared.isEnabled {
            for fillerWord in FillerWordManager.shared.fillerWords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let text = NSMutableString(string: filteredText)
                for match in regex.matches(in: filteredText, range: NSRange(location: 0, length: text.length)).reversed() {
                    let startedSentence = text.substring(with: match.range).first?.isUppercase == true
                    text.deleteCharacters(in: match.range)
                    // "Uh yeah." -> "Yeah.", not "yeah."
                    let next = text.rangeOfCharacter(from: .letters, range: NSRange(location: match.range.location, length: text.length - match.range.location))
                    if startedSentence, next.location != NSNotFound {
                        text.replaceCharacters(in: next, with: text.substring(with: next).uppercased())
                    }
                }
                filteredText = text as String
            }
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }

    static func applyUserCleanupPreferences(_ text: String) -> String {
        let shouldRemovePunctuation = UserDefaults.standard.bool(forKey: removePunctuationKey)
        let shouldLowercase = UserDefaults.standard.bool(forKey: lowercaseTranscriptionKey)

        guard shouldRemovePunctuation || shouldLowercase else {
            return text
        }

        var cleanedText = text
        if shouldRemovePunctuation {
            cleanedText = removePunctuation(from: cleanedText)
        }
        if shouldLowercase {
            cleanedText = cleanedText.lowercased()
        }

        return cleanedText
    }

    static func removePunctuation(from text: String) -> String {
        guard !text.isEmpty else { return text }

        let punctuationSeparators = CharacterSet.punctuationCharacters.subtracting(apostropheLikeCharacters)
        let cleanedScalars = text.unicodeScalars.map { scalar -> String in
            if apostropheLikeCharacters.contains(scalar) {
                return ""
            }

            if punctuationSeparators.contains(scalar) {
                return " "
            }

            return String(scalar)
        }

        return normalizeWhitespace(cleanedScalars.joined())
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[^\S\r\n]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
} 
