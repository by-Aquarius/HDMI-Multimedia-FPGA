# Validate that the portable .al source references and original constraints open
# under TD, then re-signoff the delivered routed DB.
file mkdir validation_reports

open_project ../HDMI_MULTIMEDIA_FINAL.al
import_device eagle_s20.db -package EG4S20BG256
import_db r298_pr2_seed3_routed.db
read_adc ../../constraints/media_terminal_top.adc
read_sdc ../../constraints/media_terminal_top.sdc

report_timing -mode FINAL -net_info -rpt_autogen true -file validation_reports/timing.rpt
report_timing -mode FINAL -file validation_reports/timing_simple.rpt
report_timing_exception -file validation_reports/timing_exception.rpt
report_timing_ignored -file validation_reports/timing_ignored.rpt
report_clock_summary -mode FINAL -file validation_reports/clock_summary.rpt
report_clock_intersection -file validation_reports/clock_intersection.rpt
report_area -io_info -file validation_reports/area.rpt
report_io -file validation_reports/io.rpt -verbose

close_project
exit 0
