# BENCHWIN2: Praat jitter/shimmer of one WAV, the settings JITTER-EST compared against (cc point process 75-600 Hz;
# Praat's default local-jitter limits 0.0001 ... 0.02 s, period factor 1.3, amplitude factor 1.6). Prints one CSV line:
# path,jitter_local_pct,jitter_ppq5_pct,shimmer_local_pct,npoints
form Jitter
  sentence infile
endform
s = Read from file: infile$
selectObject: s
pp = To PointProcess (periodic, cc): 75, 600
n = Get number of points
jl = Get jitter (local): 0, 0, 0.0001, 0.02, 1.3
jp = Get jitter (ppq5): 0, 0, 0.0001, 0.02, 1.3
selectObject: s, pp
sl = Get shimmer (local): 0, 0, 0.0001, 0.02, 1.3, 1.6
writeInfoLine: infile$, ",", fixed$(jl * 100, 5), ",", fixed$(jp * 100, 5), ",", fixed$(sl * 100, 5), ",", n
