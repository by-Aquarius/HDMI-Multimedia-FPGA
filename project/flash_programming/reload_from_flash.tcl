puts "HDMI_PR2SEED3_FLASH_RELOAD_BEGIN"
set reload_code [catch {
    program -r -cable 0 -spd 7
} reload_message reload_options]
puts "HDMI_PR2SEED3_FLASH_RELOAD_CODE=$reload_code MESSAGE=$reload_message OPTIONS=$reload_options"
puts "HDMI_PR2SEED3_FLASH_RELOAD_END"
if {$reload_code != 0} {
    exit 1
}
exit 0
