import Foundation
import Testing
@testable import VoiceInk

struct TranscriptionOutputFilterTests {
    @Test func keepsBracketedSpeech() {
        #expect(TranscriptionOutputFilter.filter("Call foo(bar) and check [the docs].") == "Call foo(bar) and check [the docs].")
    }

    @Test func removesNonSpeechTags() {
        #expect(TranscriptionOutputFilter.filter("[BLANK_AUDIO]") == "")
        #expect(TranscriptionOutputFilter.filter("Hello (upbeat music) world [ Silence ]") == "Hello world")
    }

    @Test func recapitalizesAfterLeadingFiller() async {
        await withDefaults(["RemoveFillerWords": true]) {
            #expect(TranscriptionOutputFilter.filter("Uh yeah. Um, okay, I said um hello.") == "Yeah. Okay, I said hello.")
        }
    }
}
