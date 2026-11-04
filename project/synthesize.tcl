set script_dir [file dirname [file normalize [info script]]]
set package_root [file normalize [file join $script_dir ..]]
cd $script_dir

open_project "HDMI_MULTIMEDIA_FINAL.al"
import_device eagle_s20.db -package EG4S20BG256
elaborate -top media_terminal_top
read_adc [file join $package_root constraints media_terminal_top.adc]
optimize_rtl
read_sdc [file join $package_root constraints media_terminal_top.sdc]

file mkdir reports
report_area -file reports/final_rtl.area
set_param gate opt_area high
set_param gate opt_timing high
optimize_gate -maparea reports/final_gate.area
legalize_phy_inst
export_db final_gate.db
close_project
exit
