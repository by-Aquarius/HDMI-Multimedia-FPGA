# audio_fifo specification

Status: functional repair contract; strict formatter/AST and governed WaveDrom SVG
generation remain unavailable/failed and are not represented as passed.

PCM byte pairing and synchronous BRAM FIFO in the 50MHz audio domain. Little endian
byte pairs represent signed mono 16-bit PCM. Production DEPTH=2048, LOW_WATER=512.
The physical address width is 11 bits; this implementation's wrap contract is DEPTH=2048.

| Port | Direction/width | Contract |
|---|---|---|
| clk | input 1 | 50MHz, rising edge |
| rst_n | input 1 | asynchronous active-low reset |
| flush | input 1 | synchronous reset of byte fragment, pointers, flags and forward record |
| pcm_valid | input 1 | one accepted incoming byte this cycle |
| pcm_data | input 8 | low byte, then high byte |
| pcm_last | input 1 | last data byte; low-byte termination sets format_error |
| sample_tick | input 1 | read attempt; production spacing 1041/1042 clocks |
| sample_out | output 16 | oldest complete sample, zero on empty tick |
| sample_valid | output 1 | registered sample_tick, suppressed by reset/flush |
| underrun | output 1 | most recent tick was empty; next successful read clears it |
| low_water | output 1 | fill_level <= LOW_WATER |
| full | output 1 | fill_level == DEPTH |
| overflow | output 1 | sticky rejected complete-word write when full |
| format_error | output 1 | sticky incomplete final sample |
| stream_done | output 1 | sticky last high byte received |
| fill_level | output 12 | number of complete queued samples |

Cycle behavior: a complete write increments count unless a read also occurs. A
nonempty sample_tick reads and advances the read pointer. A write one edge before
the read may collide with the BRAM prefetch and return old memory contents. The
candidate records that accepted write's address/data for exactly one clock and
forwards it on address match. Read and sample_valid latency remain unchanged.
Same-edge empty read+write still reports underrun and retains the new sample for
the next read. Reset and flush cancel forwarding, byte fragments and pending data.
No ready/valid interface or FSM is added. No clock phase is changed.

Verification: actual Anlogic EG_LOGIC_BRAM/EG_PHY_BRAM32K library, refill offset sweep,
address wrap, signed rails, true PCM zero, empty read, flush, and existing 32768-word
FIFO regression. Post-route setup/hold analysis remains required; functional
simulation does not establish BRAM pin timing or identify a physical field cause.

Timing scenario `empty_refill_next_edge`: high byte commits on edge W, sample_tick
on edge W+1 must return the newly committed word despite stale BRAM output.

```json
{"signal":[{"name":"clk","wave":"p...."},{"name":"pcm_valid","wave":"01100"},{"name":"pcm_data","wave":"x==xx","data":["low","high"]},{"name":"sample_tick","wave":"00010"},{"name":"sample_valid","wave":"00001"},{"name":"sample_out","wave":"x...=","data":["new PCM"]}]}
```
