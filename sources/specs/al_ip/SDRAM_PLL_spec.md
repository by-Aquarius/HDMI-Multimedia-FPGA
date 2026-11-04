# SDRAM_PLL specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Preserved analog loop with 50MHz outputs.

Contract: REFDIV1, FBDIV1, C0DIV20/C1DIV20, CPHASE19/FPHASE0. VCO1000MHz/PFD50MHz/feedback total20 and original analog settings retained. Both outputs50MHz aligned; C2 unused10MHz. Vendor PLL model has inherited scalar/vector load_reg warning; do not alter vendor simulation code.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module SDRAM_PLL(refclk,
		reset,
		clk0_out,
		clk1_out,
		clk2_out);
```

Verification evidence: validation/memory_pll.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

Timing review: asynchronous reset asserts immediately. POS source data settles before NEG capture; subsequent POS consumer sees the same source value as before. Memory pin outputs use NEG and input capture POS. Exact bank/mailbox timing and CRC invariants are tested in the real implementation testbench, not established by this illustrative waveform.

```json
{
  "signal": [
    {
      "name": "clk_POS_NEG",
      "wave": "p......."
    },
    {
      "name": "producer_bundle",
      "wave": "x.3.4.5.",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "NEG_capture",
      "wave": "x..3.4.5",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "POS_consumer",
      "wave": "x...3.4.",
      "data": [
        "A",
        "B"
      ]
    }
  ],
  "head": {
    "text": "Conceptual half-cycle bundle; POS writes unchanged (review draft)"
  },
  "config": {
    "hscale": 2
  }
}
```
