# fat32_dir_scanner specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: FAT directory entry cluster timing.

Contract: Accumulate high/low cluster bytes at fixed directory offsets. Capture complete32bit cluster value NEG, use at original offset31 POS emission; latest cluster byte arrives offset27. Two-sector28file parser outputs identical cycle by cycle. Reader handshake requires request_ready; bench explicitly holds ready until request observed.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module fat32_dir_scanner #(
    parameter integer INDEX_WIDTH = 4,
    parameter integer MAX_MEDIA_FILES = (1 << INDEX_WIDTH),
    parameter integer SINGLE_SECTOR_READS = 1
) (
    input  wire                         clk_50m,
    input  wire                         rst_n,
    input  wire                         start,

    // C04 FAT32 layout outputs.
    input  wire [31:0]                  first_data_lba,
    input  wire [31:0]                  root_cluster,
    input  wire [7:0]                   sectors_per_cluster,

    // C03 sector-reader request/response stream.
    output wire                         reader_req_valid,
    output reg  [31:0]                  reader_req_lba,
    output reg  [15:0]                  reader_req_count,
    input  wire                         reader_req_ready,
    input  wire                         reader_rsp_valid,
    input  wire [7:0]                   reader_rsp_data,
    input  wire                         reader_rsp_last,
    input  wire [7:0]                   reader_rsp_error,

    output wire                         busy,
    output reg                          done,
    output reg                          fat32_dir_valid,
    output reg  [7:0]                   error_code,

    // Media event stream. media_valid/index_wr_en pulse for one accepted file.
    output reg                          media_valid,
    output reg  [INDEX_WIDTH-1:0]       media_index,
    output reg  [87:0]                  media_name_83,
    output reg  [1:0]                   media_type,
    output reg  [31:0]                  media_first_cluster,
    output reg  [31:0]                  media_file_size,
    output reg  [7:0]                   media_count,

    // Write port for media_index_ram.
    output reg                          index_wr_en,
    output reg  [INDEX_WIDTH-1:0]       index_wr_index,
    output reg  [87:0]                  index_wr_name_83,
    output reg  [1:0]                   index_wr_type,
    output reg  [31:0]                  index_wr_first_cluster,
    output reg  [31:0]                  index_wr_file_size
);
```

Verification evidence: validation/directory_bundle.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

Timing review: asynchronous reset asserts immediately. POS source data settles before NEG capture; subsequent POS consumer sees the same source value as before. Memory pin outputs use NEG and input capture POS. Exact bank/mailbox timing and CRC invariants are tested in the real implementation testbench, not established by this illustrative waveform.

```json
{
  "signal": [
    {
      "name": "clk_POS_NEG",
      "wave": "p......."
    },
    {
      "name": "producer_bundle",
      "wave": "x.3.4.5.",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "NEG_capture",
      "wave": "x..3.4.5",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "POS_consumer",
      "wave": "x...3.4.",
      "data": [
        "A",
        "B"
      ]
    }
  ],
  "head": {
    "text": "Conceptual half-cycle bundle; POS writes unchanged (review draft)"
  },
  "config": {
    "hscale": 2
  }
}
```
