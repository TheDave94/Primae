# ENVGAP: Praat PSOLA reference render (BENCH-R31's documented procedure: To Manipulation 0.01 75 600,
# Multiply frequencies, Get resynthesis (overlap-add)).  Usage: Praat --run praat_psola.praat in.wav out.wav cents
form PSOLA
  sentence infile
  sentence outfile
  real cents 600
endform
s = Read from file: infile$
m = To Manipulation: 0.01, 75, 600
pt = Extract pitch tier
Multiply frequencies: 0, 1000, 2 ^ (cents / 1200)
selectObject: m, pt
Replace pitch tier
selectObject: m
r = Get resynthesis (overlap-add)
Save as WAV file: outfile$
