# Rebuild the accepted physical result from the original H43 gate database.
# Run this file from project/hold_fix_pr2_seed3 through run_td_ascii.ps1.
file mkdir repro_reports
file mkdir repro_outputs

open_project ../HDMI_MULTIMEDIA_FINAL.al
import_device eagle_s20.db -package EG4S20BG256
import_db r298_gate.db
read_adc ../../constraints/media_terminal_top.adc
read_sdc ../../constraints/media_terminal_top.sdc

# The original successful baseline used pr_strategy=2, high opt_timing,
# place/route fix_hold=on, and timing-priority routing. The only experiment
# variable is placement seed=3.
set_param place seed 3
set_param place effort high
set_param place opt_timing high
set_param place fix_hold on
set_param place post_clock_route_opt on
set_param place pr_strategy 2
set_param place new_spreading on
set_param route effort high
set_param route opt_timing high
set_param route fix_hold on
set_param route priority timing

report_param -step place -detail -file repro_reports/place_params.rpt
report_param -step route -detail -file repro_reports/route_params.rpt

puts "HDMI_PR2_SEED3_REPRO_STAGE=PLACE"
set place_code [catch {place} place_message place_options]
puts "HDMI_PR2_SEED3_REPRO_PLACE_CODE=$place_code MESSAGE=$place_message OPTIONS=$place_options"
if {$place_code != 0} {
    export_db repro_outputs/place_failure.db
    close_project
    exit 101
}
export_db repro_outputs/r298_pr2_seed3_place.db

puts "HDMI_PR2_SEED3_REPRO_STAGE=ROUTE"
set route_code [catch {route} route_message route_options]
puts "HDMI_PR2_SEED3_REPRO_ROUTE_CODE=$route_code MESSAGE=$route_message OPTIONS=$route_options"
if {$route_code != 0} {
    report_timing -mode FINAL -file repro_reports/route_failure_timing.rpt
    export_db repro_outputs/route_failure.db
    close_project
    exit 102
}

report_timing -mode FINAL -net_info -rpt_autogen true -file repro_reports/final_timing.rpt
report_timing -mode FINAL -file repro_reports/final_timing_simple.rpt
report_timing_exception -file repro_reports/final_timing_exception.rpt
report_timing_ignored -file repro_reports/final_timing_ignored.rpt
report_clock_summary -mode FINAL -file repro_reports/final_clock_summary.rpt
report_clock_intersection -file repro_reports/final_clock_intersection.rpt
report_area -io_info -file repro_reports/final_area.rpt
report_io -file repro_reports/final_io.rpt -verbose
write_verilog repro_outputs/r298_pr2_seed3_routed.v -implement
export_db repro_outputs/r298_pr2_seed3_routed.db

close_project
exit 0
