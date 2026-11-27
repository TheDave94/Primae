// SonificationGoldens.swift
// PrimaeNativeTests — protocol r17 regression suite
//
// Recorded fingerprints of `SonificationRegressionTests.trajectoryRender`:
// 40 block RMS values per source (TDPSOLA). Tolerance 1e-3 relative (the
// simulator's and the iPad's vDSP/libm may differ in the last bits; an
// algorithm change moves these by far more). To re-record after a DELIBERATE
// change: run the suite; each failure prints the new literal.

nonisolated enum SonificationGoldens {
    /// Recorded on the physical iPad (iPad13,8, iOS 27.2), Debug-Study, 2026-11-03, after the OPT-T
    /// rebase and the r17 tuning (tau 2 ms). A_phoneme1 re-recorded 2026-11-03 after TDQ (the pulse limiter moves A's blocks by 0.16 %).
    /// A, I, M re-recorded 2026-11-04 after POP2 (the shipped A, I, M phoneme files were equalised offline per pitch period by scripts/equalise_phoneme_periods.sh, smoothing 120 ms; the blocks move by 1.8-2.8 %; F, L and the carrier did not move). All five phonemes re-recorded 2026-11-04 after SEAM2 (the trajectory drive passes the loop wrap; the prepared loop moves blocks by up to 6 %; the carrier is not processed and did not move).
    /// A, F, I, L, M re-recorded 2026-11-06 (R17D) on the iPad (iPad13,8, iOS 27.2), Debug-Study: the onset + loop files
    /// (A/I/L/M onsets, F = F_ONSET1 + L5), the declared attack ends, F not time-stretched (U1). The carrier is unchanged.
    /// A, I, L, M re-recorded 2026-11-26 (protocol r31, lane PITCHWIN) on the iPad (iPad13,8, iOS 27.2), Debug-Study, from the
    /// printed literals: the phoneme arm now renders with TDPSOLA2 `.production` (items 1-5, the shifted attack at the steady F0,
    /// item 8). F (0 cents in this drive: item 8 is exactly 1 there) and the carrier are unchanged and were not re-recorded.
    static let fingerprints: [String: [Double]] = [
        "A_phoneme1": [0.12168, 0.113102, 0.0864787, 0.0794086, 0.082605, 0.0755654, 0.0729007, 0.0737542, 0.07352, 0.0759185, 0.0731244, 0.0756602, 0.0743265, 0.0750879, 0.0529263, 0, 0, 0.0121147, 0.142161, 0.101123, 0.081096, 0.079604, 0.0840135, 0.0709826, 0.0742883, 0.0737527, 0.0760583, 0.0736958, 0.0706029, 0.0122031, 0.142656, 0.100607, 0.0823533, 0.0785269, 0.0841112, 0.070726, 0.0747114, 0.0741123, 0.0740973, 0.0751923],
        "F_phoneme1": [0.015838, 0.0484636, 0.0519086, 0.0504784, 0.0496775, 0.0492258, 0.0485517, 0.0496919, 0.0492216, 0.0500098, 0.0480788, 0.0501782, 0.0482313, 0.0499711, 0.0357024, 0, 0, 0.00297594, 0.026552, 0.0552108, 0.0491577, 0.0504916, 0.0503134, 0.0473069, 0.0505969, 0.0484322, 0.0498807, 0.0492165, 0.0456415, 0.00332694, 0.0273378, 0.0552437, 0.0491878, 0.050194, 0.0505375, 0.0472407, 0.0506709, 0.0482378, 0.0498909, 0.0493808],
        "I_phoneme1": [0.0155895, 0.0856087, 0.0802102, 0.0782594, 0.0781589, 0.0803707, 0.0795886, 0.0777312, 0.0791546, 0.0807078, 0.078528, 0.0779797, 0.0801615, 0.0778458, 0.0557772, 0, 0, 0.00450149, 0.0600249, 0.0789472, 0.078119, 0.0795936, 0.0783301, 0.0803042, 0.0779598, 0.079869, 0.0781367, 0.0789184, 0.0748871, 0.00451464, 0.0613121, 0.0784001, 0.0786049, 0.0789475, 0.0801604, 0.0783151, 0.0780943, 0.0802781, 0.0810843, 0.0778246],
        "L_phoneme1": [0.0510375, 0.0738651, 0.0756261, 0.0768149, 0.0775886, 0.0769036, 0.075458, 0.0751748, 0.0763723, 0.0766213, 0.0765737, 0.0765456, 0.075568, 0.0766382, 0.0546986, 0, 0, 0.00552785, 0.0672334, 0.073907, 0.0765647, 0.0769462, 0.0757606, 0.0767591, 0.0765244, 0.0761068, 0.0756394, 0.0765436, 0.072348, 0.00693637, 0.0678212, 0.074277, 0.0765515, 0.0774031, 0.076008, 0.0751534, 0.0765339, 0.0770089, 0.076514, 0.0764824],
        "M_phoneme1": [0.0440014, 0.0815628, 0.0776935, 0.0790743, 0.0800689, 0.0805733, 0.0800636, 0.0796933, 0.0796682, 0.0795786, 0.080311, 0.0798535, 0.0801836, 0.080052, 0.0558905, 0, 0, 0.00774634, 0.0637533, 0.0803038, 0.0787978, 0.0805514, 0.0797994, 0.0795597, 0.0801486, 0.0802363, 0.0805557, 0.0799766, 0.0745465, 0.0105365, 0.0646766, 0.0802859, 0.0787751, 0.0798485, 0.0803141, 0.079964, 0.0795892, 0.079639, 0.0793657, 0.080118],
        "spatial_carrier": [0.142617, 0.146315, 0.146514, 0.146676, 0.146368, 0.145615, 0.14657, 0.14674, 0.146235, 0.145912, 0.146271, 0.146657, 0.146403, 0.145788, 0.104054, 0, 0, 0.083884, 0.146251, 0.1465, 0.14611, 0.146568, 0.146343, 0.145976, 0.146634, 0.146031, 0.146405, 0.14615, 0.138872, 0.0860427, 0.146258, 0.146216, 0.146286, 0.14634, 0.146569, 0.146204, 0.146441, 0.1463, 0.146177, 0.146424],
    ]
}
