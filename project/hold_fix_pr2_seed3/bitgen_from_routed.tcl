# Regenerate and re-signoff the delivered bitstream from the accepted DB.
file mkdir bitgen_reports

open_project ../HDMI_MULTIMEDIA_FINAL.al
import_device eagle_s20.db -package EG4S20BG256
import_db r298_pr2_seed3_routed.db
read_adc ../../constraints/media_terminal_top.adc
read_sdc ../../constraints/media_terminal_top.sdc

report_timing -mode FINAL -net_info -rpt_autogen true -file bitgen_reports/pre_bitgen_timing.rpt
report_timing -mode FINAL -file bitgen_reports/pre_bitgen_timing_simple.rpt
report_area -io_info -file bitgen_reports/pre_bitgen_area.rpt
report_io -file bitgen_reports/pre_bitgen_io.rpt -verbose

set bit_code [catch {
    bitgen -bit HDMI_MULTIMEDIA_FINAL_1280x720_60_PR2SEED3_REPRO.bit
} bit_message bit_options]
puts "HDMI_PR2_SEED3_REPRO_BITGEN_CODE=$bit_code MESSAGE=$bit_message OPTIONS=$bit_options"

report_timing -mode FINAL -net_info -rpt_autogen true -file bitgen_reports/post_bitgen_timing.rpt
report_timing -mode FINAL -file bitgen_reports/post_bitgen_timing_simple.rpt
report_timing_exception -file bitgen_reports/post_bitgen_timing_exception.rpt
report_timing_ignored -file bitgen_reports/post_bitgen_timing_ignored.rpt
report_clock_summary -mode FINAL -file bitgen_reports/post_bitgen_clock_summary.rpt
report_clock_intersection -file bitgen_reports/post_bitgen_clock_intersection.rpt
report_area -io_info -file bitgen_reports/post_bitgen_area.rpt
report_io -file bitgen_reports/post_bitgen_io.rpt -verbose

close_project
if {$bit_code != 0} {
    exit 120
}
exit 0
