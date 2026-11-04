set script_dir [file dirname [file normalize [info script]]]
set package_root [file normalize [file join $script_dir ..]]
cd $script_dir

open_project "HDMI_MULTIMEDIA_FINAL.al"
import_device eagle_s20.db -package EG4S20BG256
import_db final_gate.db
read_adc [file join $package_root constraints media_terminal_top.adc]
read_sdc [file join $package_root constraints media_terminal_top.sdc]

file mkdir reports
set_param place effort high
set_param place opt_timing high
set_param place fix_hold on
set_param place post_clock_route_opt on
set_param place pr_strategy 2
set_param place new_spreading on
set_param route effort high
set_param route opt_timing high
set_param route fix_hold on

place
export_db final_place.db
route
export_db final_routed.db
if {1} {
    fix_hold
    export_db final_hold.db
}
report_area -io_info -file reports/final_phy.area
report_clock_summary -mode FINAL -file reports/final_clock_summary.rpt
report_timing -mode FINAL -net_info -rpt_autogen true -file reports/final_timing.rpt
report_timing -mode FINAL -file reports/final_timing_simple.rpt
export_bid final.inst.bid

set timing_handle [open reports/final_timing_simple.tsm r]
gets $timing_handle ignored
gets $timing_handle ignored
gets $timing_handle slack_line
close $timing_handle
if {[lindex $slack_line 0] < 0 || [lindex $slack_line 1] < 0} {
    puts stderr "HDMI_FINAL_TIMING_FAILED: $slack_line"
    close_project
    exit 2
}

bitgen -bit reports/HDMI_MULTIMEDIA_FINAL_1280x720_60.bit
close_project
exit
