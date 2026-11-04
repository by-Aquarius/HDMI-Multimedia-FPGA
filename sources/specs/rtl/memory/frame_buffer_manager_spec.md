# frame_buffer_manager specification review draft

Status: repair contract; strict formatter/AST and governed WaveDrom bundle are not approved.

Two RGB565 pixels form one32-bit SDRAM word. Source coordinates must remain row-major. load_start chooses the opposite displayed bank and invalidates that back bank. Only a complete error-free frame can be committed at a frame boundary after a swap request. show_frame_select changes only on that commit. pixel_ready, mem_wr_valid/ready/done and swap_ack retain their original clock latency and active-low asynchronous reset.

After commit, load_frame_select may equal show_frame_select until the next load_start. load_abort resets the pending loader and swap transaction, but clears frame_ready[load_frame_select] only if that buffer is not displayed. It preserves the visible frame during a new file open/header gap, repeated aborts, failed/timeout loads, and a canceled ready back buffer. Reset still invalidates both frames. The displayed bank is never written.

```json
{"signal":[{"name":"clk","wave":"p......."},{"name":"front_ready","wave":"1......."},{"name":"file_open_abort","wave":"010....."},{"name":"header_gap","wave":"0.1..0.."},{"name":"back_load_start","wave":"0....10."},{"name":"back_ready","wave":"0......1"},{"name":"show_select","wave":"3.......","data":["old front retained"]}]}
```

Verification: tb_front_frame_abort.v old failure/new612checks; full timed memory path with realistic file abort before header-start; native full-player setup/hold; live playback samples during LOAD must retain front-ready.
