puts "HDMI_PR2SEED3_FLASH_PROGRAM_BEGIN"
if {[catch {
    download \
        -bit C:/Temp/HDMI_MULTIMEDIA_FINAL_SUBMISSION_PR2SEED3/bitstream/HDMI_MULTIMEDIA_FINAL_1280x720_60.bit \
        -mode program_spi \
        -v \
        -spd 7 \
        -sec 64 \
        -cable 0 \
        -flashsize 128
} program_error program_options]} {
    puts stderr "HDMI_PR2SEED3_FLASH_PROGRAM_FAILED: $program_error"
    puts stderr "OPTIONS: $program_options"
    exit 1
}
puts "HDMI_PR2SEED3_FLASH_PROGRAM_COMPLETED"
exit 0
