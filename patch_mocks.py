import sys

def patch_file(filepath, class_name):
    with open(filepath, 'r') as f:
        text = f.read()

    # Find the class definition
    if class_name in text:
        # Add the empty func implementation
        text = text.replace(
            'func resumeAfterLifecycle() {}',
            'func resumeAfterLifecycle() {}\n    func cancelPendingLifecycleWork() {}'
        )
        with open(filepath, 'w') as f:
            f.write(text)

patch_file('ios-native/BuchstabenNativeTests/HapticEngineTests.swift', 'TrackingMockAudio')
patch_file('ios-native/BuchstabenNativeTests/VoiceOverAccessibilityTests.swift', 'LocalMockAudioController')

