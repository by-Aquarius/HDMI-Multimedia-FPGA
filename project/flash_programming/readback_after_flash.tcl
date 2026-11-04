puts "HDMI_PR2SEED3_FLASH_READBACK_BEGIN"
set readback_code [catch {
    read_flash \
        -start_addr 0 \
        -length 16777216 \
        -output flash_after_16MiB.bin \
        -cable 0
} readback_message readback_options]
puts "HDMI_PR2SEED3_FLASH_READBACK_CODE=$readback_code MESSAGE=$readback_message OPTIONS=$readback_options"
puts "HDMI_PR2SEED3_FLASH_READBACK_END"
if {$readback_code != 0} {
    exit 1
}
exit 0
