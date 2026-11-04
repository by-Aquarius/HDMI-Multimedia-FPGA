# adaptive_aspect_raster_mapper

## 职责与时钟

整数DDA保比例缩放；本顶层实例为1280×720，图像内容窗口left400,width880,top16,height656，源最大640×480。左侧352像素宽区域保留给OSD、频谱和波形。模块通用默认仍是旧1024画布，由实例参数覆盖。

## 实际模块接口

```verilog
module adaptive_aspect_raster_mapper #(
    parameter integer C_DST_WIDTH         = 1280,
    parameter integer C_DST_HEIGHT        = 1024,
    parameter integer C_CONTENT_LEFT      = 0,
    parameter integer C_CONTENT_TOP       = 32,
    parameter integer C_CONTENT_WIDTH     = 1280,
    parameter integer C_CONTENT_HEIGHT    = 960,
    parameter integer C_MAX_SOURCE_WIDTH  = 640,
    parameter integer C_MAX_SOURCE_HEIGHT = 480
) (
    input  wire        i_clk,
    input  wire        i_rstn,

    input  wire [11:0] i_source_width,
    input  wire [11:0] i_source_height,
    input  wire        i_frame_start,
    input  wire        i_line_start,
    input  wire [11:0] i_line_y,
    input  wire        i_raster_de,
    input  wire [11:0] i_raster_x,
    input  wire [11:0] i_raster_y,
    input  wire        i_line_ready,

    output wire [11:0] o_source_width,
    output wire [11:0] o_source_height,
    output wire [12:0] o_dst_x0,
    output wire [12:0] o_dst_x1,
    output wire [12:0] o_dst_y0,
    output wire [12:0] o_dst_y1,
    output wire        o_line_req_pulse,
    output wire [11:0] o_line_req_y,
    output wire        o_pixel_req_valid,
    output wire [11:0] o_pixel_req_x,
    output wire [11:0] o_pixel_req_y
);

```

## 周期、复位与数据合同

低有效异步复位将scale_ready_q置0，强制首次几何计算；避免默认640×480尺寸与复位缓存相同时跳过计算。仅尺寸变化时执行几何除法，像素通路保持DDA，无逐像素除法。水平方向在`C_CONTENT_LEFT..C_CONTENT_LEFT+C_CONTENT_WIDTH`内按同一比例居中；4:3源在880×656窗口中显示为874×656，x起点为403。

## 证据及限制

geometry_before_fix记录720p默认尺寸失败；adaptive_aspect_raster_mapper修复后18484项，覆盖初始640×480及不同横竖比例、边界与源坐标。

本规格经过人工接口核对；严格门禁与受管WaveDrom渲染未通过的限制不作豁免，不声称全ASIC签核或已生成SVG。
