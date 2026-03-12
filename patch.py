import sys

with open('ios-native/BuchstabenNative/Core/AudioEngine.swift', 'r') as f:
    text = f.read()

text = text.replace(
    'final class AudioEngine: AudioControlling {',
    'final class AudioEngine: @unchecked Sendable, AudioControlling {'
)

with open('ios-native/BuchstabenNative/Core/AudioEngine.swift', 'w') as f:
    f.write(text)

