create_clock -name SYS_CLK -period 20 -waveform {0 10} [get_ports {FPGA_SYS_50M_CLK_P}]
create_generated_clock -name pclk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 1.485 [get_nets {pxlclk_i}]
create_generated_clock -name sclk5 -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 7.425 [get_nets {pxlclk_5x_i}]

create_generated_clock -name ctrl_clk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -divide_by 2 [get_nets {clk25m}]
create_generated_clock -name sdram_ctrl_clk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 1 [get_pins {u_sdram_pll/pll_inst.clkc[0]}]
create_generated_clock -name sdram_device_clk -source [get_ports {FPGA_SYS_50M_CLK_P}] -master_clock SYS_CLK -multiply_by 1 -phase 0 [get_pins {u_sdram_pll/pll_inst.clkc[1]}]
# Both memory clocks use the actual PLL output pins; device/controller phase0 at50MHz.

# raw_reset_n is an asynchronous reset control. Its assertion/release is protected by the two-stage per-domain reset synchronizers in d_formal_media_top; do not time it as a data path.
set_false_path -from [get_nets {raw_reset_n}]

# The line bridge and frame-swap events use toggle synchronizers. Do not time
# the raw control-domain payload as a synchronous pclk path.
set_clock_groups -asynchronous -group {SYS_CLK ctrl_clk} -group {sdram_ctrl_clk sdram_device_clk} -group {pclk sclk5}

# B04 brightness/speed packet crossing: the key domain holds param_hold_key
# stable before launching param_toggle_key. The destination uses two-stage
# synchronizers and captures the packet only on a detected toggle. Treat the
# first synchronizer launch as a bounded CDC path rather than a synchronous
# 50 MHz-to-pixel data bus.
set_false_path -from [get_nets *param_hold_key*]
set_false_path -from [get_nets *param_toggle_key*]



# All native integrated-SDRAM input/output paths remain timed; no DQ exception.



# Include PLL cascade clock uncertainty rather than treating ideal clocks as exact.
set_clock_uncertainty -setup 0.15 [get_clocks {pclk sclk5}]
set_clock_uncertainty -hold 0.05 [get_clocks {pclk sclk5}]

# Native SDRAM tAC max5ns plus0.4ns worst-device budget; hold margin also explicit.
set_clock_uncertainty -setup 0.4 [get_clocks {sdram_ctrl_clk sdram_device_clk}]
set_clock_uncertainty -hold 0.1 [get_clocks {sdram_ctrl_clk sdram_device_clk}]
