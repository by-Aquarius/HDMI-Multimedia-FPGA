# HDMI Multimedia FPGA Source

Final source snapshot for the Anlogic EG4S20BG256 multimedia terminal.

## Contents

- `sources/`: RTL (Verilog/VHDL) and design specifications.
- `assets/`: font and voice initialization data required by the RTL, with license files.
- `host/`: MediaControl desktop application C# source, font character table, build script, and protocol notes. The prebuilt executable is not included.
- `constraints/`: ADC and SDC files.
- `project/`: Tang Dynasty project and reproducible build, timing-closure, bitgen, and flash programming scripts.
- `tests/sources/`: simulation testbench sources.
- `tools/`: packaging and delivery validation scripts.

Target: Anlogic EG4S20BG256, Tang Dynasty 5.6.151449. The accepted timing closure uses the original RTL and constraints with placement seed 3. The generated bitstream, databases, logs, and evidence package are kept in the local release folder and are intentionally omitted from this source repository.

Open `project/hold_fix_pr2_seed3/README.md` and `host/BUILD.md` for build instructions.
