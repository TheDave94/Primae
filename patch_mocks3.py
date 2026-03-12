with open('ios-native/BuchstabenNativeTests/VoiceOverAccessibilityTests.swift', 'r') as f:
    text = f.read()

text = text.replace(
    'func stop() { stopCount += 1 }',
    'func stop() { stopCount += 1 }\n    func restart() {}'
)
with open('ios-native/BuchstabenNativeTests/VoiceOverAccessibilityTests.swift', 'w') as f:
    f.write(text)
