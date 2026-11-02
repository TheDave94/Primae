// StudySpokenKeysTests.swift — A29 (audit PROTOCOL M-2).
// The keys a study child can hear are exactly the recorded set: nothing
// without a take (`.phaseDirect` had none, and D5 cut the phase).

import Testing
@testable import PrimaeNative

@Suite @MainActor struct StudySpokenKeysTests {

    @Test("studySpokenKeys is exactly RecordedPromptSet.requiredKeys")
    func spokenKeysAreTheRecordedSet() {
        #expect(StudyVoiceoverPromptPlayer.studySpokenKeys == Set(RecordedPromptSet.requiredKeys))
        #expect(!StudyVoiceoverPromptPlayer.studySpokenKeys.contains(.phaseDirect))
    }

    @Test("every spoken key has a bundled recorded take")
    func everySpokenKeyIsBundled() {
        for key in StudyVoiceoverPromptPlayer.studySpokenKeys {
            #expect(PromptPlayer.locate(key) != nil, "\(key) is spoken in a study session but has no bundled take")
        }
    }
}
