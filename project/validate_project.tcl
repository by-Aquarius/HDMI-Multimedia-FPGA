set script_dir [file dirname [file normalize [info script]]]
set package_root [file normalize [file join $script_dir ..]]
cd $script_dir

open_project "HDMI_MULTIMEDIA_FINAL.al"
import_device eagle_s20.db -package EG4S20BG256
close_project
exit
