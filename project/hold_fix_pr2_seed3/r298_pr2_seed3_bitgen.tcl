set version "D:/Users/ASUS/Desktop/FPGAANLU/task1_system/baseline/video/H43_LEFT_HUD_MODES_R298_20261103"
file mkdir reports

open_project MEDIA_TERMINAL_CTRL50_R298.al
import_device eagle_s20.db -package EG4S20BG256
import_db r298_pr2_seed3_routed_src.db
read_adc $version/rtl/top/media_terminal_top.adc
read_sdc $version/constraints/media_terminal_top.sdc

puts "R298_BITGEN_STAGE=PRE_SIGNOFF"
report_timing -mode FINAL -net_info -rpt_autogen true -file reports/pre_bitgen_timing.rpt
report_timing -mode FINAL -file reports/pre_bitgen_timing_simple.rpt
report_timing_exception -file reports/pre_bitgen_timing_exception.rpt
report_timing_ignored -file reports/pre_bitgen_timing_ignored.rpt
report_clock_summary -mode FINAL -file reports/pre_bitgen_clock_summary.rpt
report_clock_intersection -file reports/pre_bitgen_clock_intersection.rpt
report_area -io_info -file reports/pre_bitgen_area.rpt
report_io -file reports/pre_bitgen_io.rpt -verbose

# This imported-DB report is known to overstate opens even for the original
# successful baseline. It is retained only for same-method comparison. Route
# legality is established by the same-session 0-overflow route log.
report_route_status -drc -file reports/imported_db_route_status.rpt

puts "R298_BITGEN_STAGE=BITGEN"
set bit_code [catch {
    bitgen -bit HDMI_MULTIMEDIA_FINAL_1280x720_60_PR2SEED3.bit
} bit_message bit_options]
puts "R298_BITGEN_CODE=$bit_code MESSAGE=$bit_message OPTIONS=$bit_options"

puts "R298_BITGEN_STAGE=POST_SIGNOFF"
report_timing -mode FINAL -net_info -rpt_autogen true -file reports/post_bitgen_timing.rpt
report_timing -mode FINAL -file reports/post_bitgen_timing_simple.rpt
report_timing_exception -file reports/post_bitgen_timing_exception.rpt
report_timing_ignored -file reports/post_bitgen_timing_ignored.rpt
report_clock_summary -mode FINAL -file reports/post_bitgen_clock_summary.rpt
report_clock_intersection -file reports/post_bitgen_clock_intersection.rpt
report_area -io_info -file reports/post_bitgen_area.rpt
report_io -file reports/post_bitgen_io.rpt -verbose

close_project
if {$bit_code != 0} {
    exit 120
}
exit 0
