// -----------------------------------------------------------------------------
// key_command_mapper.v
// 4x4 matrix key semantic mapping for the DMZ_EG4S20 board.
//
// Input contract:
//   key_pulse[n] must be a one-clock pulse generated after matrix scanning and
//   debounce. Do not connect a raw key level directly to this module.
//
// Default mapping requested for the competition system:
//   KEY11 : previous image
//   KEY9  : next image
//   KEY10 : play / pause
//   KEY14 : brightness down
//   KEY15 : brightness up
//   KEY12 : playback speed down
//   KEY13 : playback speed up
//
// The four direction choices are parameters so a board-level polarity or
// preferred UI direction can be changed without touching playback_fsm.
// -----------------------------------------------------------------------------
module key_command_mapper #(
    parameter integer KEY_PREV        = 11,
    parameter integer KEY_NEXT        = 9,
    parameter integer KEY_PLAY_PAUSE  = 10,
    parameter integer KEY_BRIGHT_DEC  = 14,
    parameter integer KEY_BRIGHT_INC  = 15,
    parameter integer KEY_SPEED_DEC   = 12,
    parameter integer KEY_SPEED_INC   = 13
) (
    input  wire [15:0] key_pulse,

    output wire        cmd_prev,
    output wire        cmd_next,
    output wire        cmd_play_pause,
    output wire        cmd_bright_dec,
    output wire        cmd_bright_inc,
    output wire        cmd_speed_dec,
    output wire        cmd_speed_inc,
    output wire        cmd_any
);

assign cmd_prev       = key_pulse[KEY_PREV];
assign cmd_next       = key_pulse[KEY_NEXT];
assign cmd_play_pause = key_pulse[KEY_PLAY_PAUSE];
assign cmd_bright_dec = key_pulse[KEY_BRIGHT_DEC];
assign cmd_bright_inc = key_pulse[KEY_BRIGHT_INC];
assign cmd_speed_dec  = key_pulse[KEY_SPEED_DEC];
assign cmd_speed_inc  = key_pulse[KEY_SPEED_INC];

assign cmd_any = cmd_prev       |
                 cmd_next       |
                 cmd_play_pause |
                 cmd_bright_dec |
                 cmd_bright_inc |
                 cmd_speed_dec  |
                 cmd_speed_inc;

endmodule
