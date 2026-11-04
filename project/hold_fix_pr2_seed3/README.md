# pr2 / seed3 physical rebuild

This directory is the reproducible implementation evidence for the accepted
final bitstream. It starts from the original H43/R298 `r298_gate.db` and changes
only the placement seed.

## Parameters

- `place seed=3`
- `place effort=high`
- `place opt_timing=high`
- `place fix_hold=on`
- `place post_clock_route_opt=on`
- `place pr_strategy=2`
- `place new_spreading=on`
- `route effort=high`
- `route opt_timing=high`
- `route fix_hold=on`
- `route priority=timing`

The original successful baseline used `pr_strategy=2` and timing-priority
routing. Its explicit log settings are preserved here. The original default
placement seed was 2; this accepted result uses seed 3.

## Run under an ASCII path

Use the supplied wrapper from the current delivery root. It creates the ASCII
junction `C:\Temp\HDMI_MULTIMEDIA_FINAL_SUBMISSION_PR2SEED3` and invokes TD from the junction:

```powershell
.\run_td_ascii.ps1 -Mode Validate
.\run_td_ascii.ps1 -Mode Rebuild
.\run_td_ascii.ps1 -Mode Bitgen
```

`Rebuild` runs placement and routing from `r298_gate.db`. `Bitgen` regenerates a
bitstream from the delivered routed DB. No command programs the board or writes
external configuration memory.

## Stored checkpoints

- `r298_gate.db`: original mapped/gate input.
- `r298_pr2_seed3_place.db`: accepted placement checkpoint.
- `r298_pr2_seed3_routed.db`: accepted 0 setup / 0 hold routed checkpoint.

The accepted route reached 0 overflow and ended with `WNS=+0.173 ns`,
`WHS=+0.026 ns`. The original SDC has 85 mapped constraints and six clocks.
