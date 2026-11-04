set script_dir [file dirname [file normalize [info script]]]
set package_root [file normalize [file join $script_dir ..]]
set source_list [file join $package_root sources sources_release.txt]
set al_path [file join $script_dir "HDMI_MULTIMEDIA_FINAL.al"]

if {[file exists $al_path]} {
    error "Refusing to overwrite existing project: $al_path"
}

cd $script_dir
create_project HDMI_MULTIMEDIA_FINAL . -family EG4 -device EG4S20BG256

set file_handle [open $source_list r]
set source_count 0
while {[gets $file_handle line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} {
        continue
    }
    set source_path [file join .. $line]
    if {![file exists $source_path]} {
        close $file_handle
        error "Packaged source is missing: $source_path"
    }
    add_files -analyze $source_path
    incr source_count
}
close $file_handle

puts "HDMI_FINAL_SOURCE_COUNT=$source_count"
if {$source_count != 89} {
    error "Expected 89 functional sources, found $source_count"
}

top_module media_terminal_top
close_project
exit
