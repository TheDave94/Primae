# ENVGAP: Praat's PSOLA pulses for a source (the Manipulation's PointProcess), one time per line.
form Pulses
  sentence infile
  sentence outfile
endform
s = Read from file: infile$
m = To Manipulation: 0.01, 75, 600
pp = Extract pulses
n = Get number of points
deleteFile: outfile$
for i to n
  t = Get time from index: i
  appendFileLine: outfile$, fixed$(t, 7)
endfor
