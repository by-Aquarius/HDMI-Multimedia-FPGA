set version "D:/Users/ASUS/Desktop/FPGAANLU/task1_system/baseline/video/H43_LEFT_HUD_MODES_R298_20261103"
set gate_db "D:/Users/ASUS/Desktop/FPGAANLU/task1_system/_codex_audit_national_award/left_hud_modes_r298/build_repair/r298_gate.db"
file mkdir reports

open_project MEDIA_TERMINAL_CTRL50_R298.al
import_device eagle_s20.db -package EG4S20BG256
import_db $gate_db
read_adc $version/rtl/top/media_terminal_top.adc
read_sdc $version/constraints/media_terminal_top.sdc

# These are the actual settings executed in build_repair/phy.log.
# The original run did not set seed and the TD probe confirmed default seed=2.
# This experiment intentionally changes only seed from 2 to 3.
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

report_param -step gate -detail -file reports/gate_params.rpt
report_param -step place -detail -file reports/place_params.rpt
report_param -step route -detail -file reports/route_params.rpt

puts "R298_PR2_SEED3_STAGE=PLACE"
set place_code [catch {place} place_message place_options]
puts "R298_PR2_SEED3_PLACE_CODE=$place_code MESSAGE=$place_message OPTIONS=$place_options"
if {$place_code != 0} {
    report_timing -mode FINAL -file reports/place_failure_timing.rpt
    export_db r298_pr2_seed3_place_failure.db
    close_project
    exit 101
}

report_timing -mode FINAL -file reports/placed_timing_simple.rpt
write_verilog r298_pr2_seed3_placed.v -implement
export_db r298_pr2_seed3_place.db

puts "R298_PR2_SEED3_STAGE=ROUTE"
set route_code [catch {route} route_message route_options]
puts "R298_PR2_SEED3_ROUTE_CODE=$route_code MESSAGE=$route_message OPTIONS=$route_options"
if {$route_code != 0} {
    report_timing -mode FINAL -file reports/route_failure_timing.rpt
    export_db r298_pr2_seed3_route_failure.db
    close_project
    exit 102
}

puts "R298_PR2_SEED3_STAGE=REPORT"
report_clock_intersection -file reports/final_clock_intersection.rpt
report_clock_summary -mode FINAL -file reports/final_clock_summary.rpt
report_timing_exception -file reports/final_timing_exception.rpt
report_timing_ignored -file reports/final_timing_ignored.rpt
report_timing -mode FINAL -net_info -rpt_autogen true -file reports/final_timing.rpt
report_timing -mode FINAL -file reports/final_timing_simple.rpt
report_area -io_info -file reports/final.area
report_route_status -drc -file reports/final_route_status.rpt
write_verilog r298_pr2_seed3_routed.v -implement
export_db r298_pr2_seed3_routed.db

close_project
exit 0
