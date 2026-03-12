import sys

def patch_file(filepath, class_name):
    with open(filepath, 'r') as f:
        text = f.read()

    if class_name in text:
        text = text.replace(
            'func stop() {}',
            'func stop() {}\n    func restart() {}'
        )
        with open(filepath, 'w') as f:
            f.write(text)

patch_file('ios-native/BuchstabenNativeTests/HapticEngineTests.swift', 'TrackingMockAudio')
patch_file('ios-native/BuchstabenNativeTests/VoiceOverAccessibilityTests.swift', 'LocalMockAudioController')

