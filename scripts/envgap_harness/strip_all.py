import sys, re
src = open(sys.argv[1]).read()
if sys.argv[1].endswith("BakeoffSources.swift"):
    a = src.index("    /// Every phoneme1 asset + the carrier at `sampleRate`.")
    b = src.index("extension BakeoffSources {")
    # remove the function body up to the closing brace of the enum
    seg = src[a:b]
    end = seg.rindex("}")  # enum close
    src = src[:a] + seg[end:] + src[b:]
open(sys.argv[2], "w").write(src)
