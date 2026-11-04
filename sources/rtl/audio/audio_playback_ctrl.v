`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Erie
// Engineer:        Codex
//
// Create Date:     2026/10/19 00:00:00
// Design Name:     audio_playback_ctrl
// Module Name:     audio_playback_ctrl
// Description:     description/audio_playback_ctrl_Design.pdf
// Simulations:     testbench/vivado/2021.1/audio_playback_ctrl
//
// Referrences:     F01/F02/F03 audio modules
//
// Dependencies:    wav_header_parser.v, audio_fifo.v, sample_rate_tick.v, audio_pwm.v
//
// Version:         V1.0
// Revision Date:   2026/10/19 00:00:00
// History:
// Time             Version     Revised by        Contents
// 2026/10/19       V1.0        Codex             Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Erie
// 开发人员:        Codex
//
// 创建日期:        2026年10月19日
// 设计名称:        audio_playback_ctrl
// 模块名称:        audio_playback_ctrl
// 模块说明:        Description/audio_playback_ctrl_Design.pdf
// 仿真工程:        TestBench/Vivado/2021.1/audio_playback_ctrl
//
// 参考资料:        F01、F02、F03 音频模块规范
//
// 依赖文件:        wav_header_parser.v、audio_fifo.v、sample_rate_tick.v、audio_pwm.v
//
// 当前版本:        V1.0
// 修订日期:        2026年10月19日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月19日   V1.0        Codex             创建文件

// 图片节目与只读 WAV 播放的集成控制器。
module audio_playback_ctrl
#(
	parameter integer C_FIFO_DEPTH      = 2048,      // PCM FIFO 样本容量
	parameter integer C_FIFO_LOW_WATER  = 512,       // 恢复文件读取的低水位
	parameter integer C_FIFO_HIGH_WATER = 1536,      // 暂停文件读取的高水位
	parameter integer C_START_LEVEL     = 256,       // 开始采样所需的最小缓存
	parameter integer C_CLOCK_HZ        = 50000000,  // 音频控制时钟频率
	parameter integer C_SAMPLE_HZ       = 48000      // 平均采样频率
)
(
	//-----------------全局信号-----------------//
	input i_clk,                                    // 音频控制与 PWM 时钟
	input i_rstn,                                   // 低有效异步复位

	//-----------------播放控制接口-----------------//
	input [4:0]i_image_index,                       // 当前图片索引
	input i_image_playing,                          // E01 正在播放
	input i_image_paused,                           // E01 暂停或就绪
	input i_transition_active,                      // D10 转场正在执行
	input i_retry,                                  // 重试当前音轨

	//-----------------媒体索引接口-----------------//
	input i_audio_ready,                            // WAV 索引已就绪
	input [4:0]i_audio_count,                       // WAV 文件数量

	//-----------------只读文件流接口-----------------//
	input i_reader_byte_valid,                      // C06 文件字节有效
	input [7:0]i_reader_byte_data,                  // C06 文件字节数据
	input i_reader_byte_last,                       // C06 文件最后字节
	input i_reader_done,                            // C06 文件读取完成
	input [7:0]i_reader_error,                      // C06 文件读取错误码
	input i_audio_open_ready,                       // G01 接受打开请求

	//-----------------音频输出与状态-----------------//
	output o_audio_open_valid,                      // 请求打开对应 WAV
	output [4:0]o_audio_open_index,                 // 打开请求的 WAV 索引
	output o_reader_hold,                           // 请求文件读取器在扇区边界暂停
	output o_audio_pwm,                             // 板卡 Audio_PWM 信号
	output o_pwm_enable,                            // PWM 主路径有效
	output o_sample_tick_enable,                    // 48 kHz 采样节拍有效
	output [7:0]o_duty_debug,                       // PWM 占空比调试值
	output o_audio_active,                          // 当前音轨已装入且无错误
	output o_audio_error,                           // 音频错误保持标志
	output [7:0]o_audio_error_code,                 // 音频错误码
	output o_audio_underrun,                        // FIFO 下溢状态
	output o_audio_track_done,                      // 最后样本已播完
	output o_audio_missing,                         // 当前图片没有对应 WAV
	output [4:0]o_audio_index,                      // 当前关联的 WAV 索引
	output [11:0]o_fill_level,                      // FIFO 当前样本数
	output [15:0]o_pcm_sample,                      // 当前 48 kHz PCM 样本（给频谱）
	output o_pcm_valid                              // PCM 样本更新脉冲
);

	//-------------状态参数区域-------------//
	localparam [2:0]ST_IDLE   = 3'd0;               // 等待媒体上下文
	localparam [2:0]ST_OPEN   = 3'd1;               // 等待打开对应 WAV
	localparam [2:0]ST_STREAM = 3'd2;               // 接收并播放 WAV 字节流
	localparam [2:0]ST_DRAIN  = 3'd3;               // 文件结束，等待 FIFO 排空
	localparam [2:0]ST_DONE   = 3'd4;               // 当前音轨播放完成
	localparam [2:0]ST_ERROR  = 3'd5;               // 音频错误且静音

	//-------------错误码区域-------------//
	localparam [7:0]ERR_SHORT_FILE = 8'hB6;         // 读取结束但 WAV 数据未完成
	localparam [7:0]ERR_FIFO_FULL  = 8'hB7;         // FIFO 在背压下溢出
	localparam [7:0]ERR_FIFO_ODD   = 8'hB8;         // FIFO 收到不完整采样

	//------------模块实例化信号------------//
	wire        wav_busy;                           // WAV 解析器忙
	wire        wav_done;                           // WAV 数据区结束脉冲
	wire        wav_error;                          // WAV 格式错误
	wire [7:0]  wav_error_code;                     // WAV 格式错误码
	wire        wav_header_done;                    // 已定位 PCM 数据区
	wire        wav_pcm_valid;                      // 已验证 PCM 字节有效
	wire [7:0]  wav_pcm_data;                       // 已验证 PCM 字节数据
	wire        wav_pcm_last;                       // PCM 数据区最后字节
	wire [15:0] fifo_sample_out;                    // FIFO 当前 PCM 样本
	wire        fifo_sample_valid;                  // FIFO 采样更新有效
	wire        fifo_underrun;                      // FIFO 下溢
	wire        fifo_low_water;                     // FIFO 低于低水位
	wire        fifo_full;                          // FIFO 已满
	wire        fifo_overflow;                      // FIFO 写入溢出
	wire        fifo_format_error;                  // FIFO 采样字节不完整
	wire        fifo_stream_done;                   // PCM 最后样本已入队
	wire [11:0] fifo_fill_level;                    // FIFO 样本数量
	wire        sample_tick_wire;                   // 48 kHz 平均采样节拍
	wire        audio_pwm_o;                        // 板卡 PWM 实例输出
	wire [7:0]  duty_debug_o;                       // PWM 实例占空比输出

	//--------------状态机信号--------------//
	reg [2:0]  state_current;                       // 当前音频状态
	reg [2:0]  state_next;                          // 次态组合结果
	reg [4:0]  assoc_index_q;                       // 已完成上下文关联的图片索引
	reg [4:0]  assoc_count_q;                       // 已采样过的 WAV 数量
	reg        assoc_ready_q;                       // 已采样过的索引就绪标志
	reg        assoc_valid_q;                       // 上下文关联已初始化
	reg [4:0]  open_index_q;                        // 当前打开请求索引

	//--------------寄存器信号--------------//
	reg        parser_start_q;                      // 新 WAV 解析启动脉冲
	reg        parser_start_pending_q;              // 复位后等待启动解析器
	reg        parser_reset_q;                      // 解析器显式复位窗口
	reg        fifo_flush_q;                        // FIFO 清空脉冲
	reg        header_done_q;                       // 已定位当前 WAV 数据区
	reg        play_started_q;                      // 当前音轨已跨过启动水位
	reg        wav_done_q;                          // 当前 WAV 数据区已完成
	reg        reader_done_q;                       // 当前文件读取已完成
	reg [7:0]  error_code_q;                        // 当前音频错误码
	reg        track_done_q;                        // 音轨结束单周期脉冲
	reg        hold_high_q;                         // FIFO 高水位背压保持
	reg        pwm_enable_q;                        // 上一周期 PWM 使能

	//---------------标志信号---------------//
	wire request_valid;                             // 当前图片有对应 WAV
	wire context_changed;                           // 图片或音频索引上下文变化
	wire track_change_now;                          // 当前周期需要清空旧音轨
	wire open_accept;                               // G01 接受打开请求
	wire play_gate;                                 // 播放且非暂停、非转场
	wire fatal_error_now;                           // 当前周期发生音频致命错误
	wire [7:0] fatal_error_code;                    // 当前音频致命错误码
	wire wav_input_valid;                           // 允许进入 WAV 解析器的字节
	wire pwm_enable_int;                            // 组合 PWM 使能
	wire force_pwm_silence;                         // 关闭 PWM 时的单周期静音锁存
	wire pwm_sample_valid;                          // PWM 采样更新或静音事件
	wire [15:0] pwm_sample_data;                    // 静音时强制为零的 PCM

	//---------------输出信号---------------//
	reg audio_error_o;                              // 音频错误状态输出缓存
	reg [7:0] audio_error_code_o;                   // 音频错误码输出缓存
	reg audio_track_done_o;                         // 音轨结束脉冲输出缓存

	//---------------其他信号---------------//
	assign request_valid = i_audio_ready &&
	                       (i_audio_count != 5'd0) &&
	                       (i_image_index < i_audio_count);
	assign context_changed = !assoc_valid_q ||
	                         (i_image_index != assoc_index_q) ||
	                         (i_audio_count != assoc_count_q) ||
	                         (i_audio_ready != assoc_ready_q);
	assign track_change_now = context_changed || i_retry;
	assign open_accept = o_audio_open_valid && i_audio_open_ready;
	assign play_gate = i_image_playing &&
	                   !i_image_paused &&
	                   !i_transition_active;
	assign pwm_enable_int = ((state_current == ST_STREAM) ||
	                         (state_current == ST_DRAIN)) &&
	                        header_done_q &&
	                        play_started_q &&
	                        play_gate &&
	                        !fatal_error_now;
	assign wav_input_valid = i_reader_byte_valid &&
	                         (state_current == ST_STREAM) &&
	                         !track_change_now &&
	                         !parser_reset_q &&
	                         !parser_start_pending_q &&
	                         !parser_start_q &&
	                         !fatal_error_now;
	assign force_pwm_silence = pwm_enable_q && !pwm_enable_int;
	assign pwm_sample_valid = fifo_sample_valid || force_pwm_silence;
	assign pwm_sample_data = force_pwm_silence ? 16'd0 : fifo_sample_out;

	assign fatal_error_now =
	    ((state_current == ST_STREAM) || (state_current == ST_DRAIN)) &&
	    !track_change_now &&
	    !parser_reset_q &&
	    !parser_start_pending_q &&
	    !parser_start_q &&
	    (wav_error ||
	     (i_reader_error != 8'd0) ||
	     (reader_done_q && !wav_done_q) ||
	     fifo_overflow ||
	     fifo_format_error);
	assign fatal_error_code =
	    wav_error ?
	        {4'hA, wav_error_code[3:0]} :
	    (i_reader_error != 8'd0) ?
	        {4'hB, i_reader_error[3:0]} :
	    (reader_done_q && !wav_done_q) ?
	        ERR_SHORT_FILE :
	    fifo_overflow ?
	        ERR_FIFO_FULL :
	        ERR_FIFO_ODD;

	//-------------输出信号连线-------------//
	assign o_audio_open_valid = (state_current == ST_OPEN) &&
	                            request_valid &&
	                            !track_change_now;
	assign o_audio_open_index = open_index_q;
	assign o_reader_hold = (state_current != ST_STREAM) ||
	                       !play_gate ||
	                       hold_high_q ||
	                       parser_reset_q ||
	                       parser_start_pending_q ||
	                       parser_start_q ||
	                       fatal_error_now;
	assign o_audio_pwm = audio_pwm_o;
	assign o_pwm_enable = pwm_enable_int;
	assign o_sample_tick_enable = pwm_enable_int;
	assign o_duty_debug = duty_debug_o;
	assign o_audio_active = ((state_current == ST_STREAM) ||
	                         (state_current == ST_DRAIN)) &&
	                        !fatal_error_now;
	assign o_audio_error = audio_error_o;
	assign o_audio_error_code = audio_error_code_o;
	assign o_audio_underrun = fifo_underrun && pwm_enable_int;
	assign o_audio_track_done = audio_track_done_o;
	assign o_audio_missing = i_audio_ready &&
	                         ((i_audio_count == 5'd0) ||
	                          (i_image_index >= i_audio_count));
	assign o_audio_index = assoc_index_q;
	assign o_fill_level = fifo_fill_level;
	assign o_pcm_sample = fifo_sample_out;
	assign o_pcm_valid  = fifo_sample_valid;

	//--------------状态机区域--------------//
	// 音频状态寄存器。
	always @(posedge i_clk or negedge i_rstn) begin
		if (i_rstn == 1'b0) begin
			state_current <= ST_IDLE;
		end else begin
			state_current <= state_next;
		end
	end

	// 音频主状态转移。
	always @(*) begin
		state_next = state_current;
		case (state_current)
			// 无音轨时的稳定等待。
			ST_IDLE: begin
				if (track_change_now && request_valid) begin
					state_next = ST_OPEN;
				end else begin
					state_next = ST_IDLE;
				end
			end
			// 等待 G01 打开对应 WAV。
			ST_OPEN: begin
				if (track_change_now) begin
					if (request_valid) begin
						state_next = ST_OPEN;
					end else begin
						state_next = ST_IDLE;
					end
				end else if (open_accept) begin
					state_next = ST_STREAM;
				end else begin
					state_next = ST_OPEN;
				end
			end
			// 接收 WAV 字节并实时输出 PCM。
			ST_STREAM: begin
				if (track_change_now) begin
					if (request_valid) begin
						state_next = ST_OPEN;
					end else begin
						state_next = ST_IDLE;
					end
				end else if (fatal_error_now) begin
					state_next = ST_ERROR;
				end else if (reader_done_q && wav_done_q) begin
					state_next = ST_DRAIN;
				end else begin
					state_next = ST_STREAM;
				end
			end
			// 文件已结束，继续消耗 FIFO。
			ST_DRAIN: begin
				if (track_change_now) begin
					if (request_valid) begin
						state_next = ST_OPEN;
					end else begin
						state_next = ST_IDLE;
					end
				end else if (fatal_error_now) begin
					state_next = ST_ERROR;
				end else if (fifo_stream_done &&
				             (fifo_fill_level == 12'd0)) begin
					state_next = ST_DONE;
				end else begin
					state_next = ST_DRAIN;
				end
			end
			// 当前音轨完成，保持静音直到换图或重试。
			ST_DONE: begin
				if (track_change_now) begin
					if (request_valid) begin
						state_next = ST_OPEN;
					end else begin
						state_next = ST_IDLE;
					end
				end else begin
					state_next = ST_DONE;
				end
			end
			// 音频错误只影响音频，等待换图或重试。
			ST_ERROR: begin
				if (track_change_now) begin
					if (request_valid) begin
						state_next = ST_OPEN;
					end else begin
						state_next = ST_IDLE;
					end
				end else begin
					state_next = ST_ERROR;
				end
			end
			// 非法状态回到安全空闲态。
			default: begin
				state_next = ST_IDLE;
			end
		endcase
	end

	//-----------主要任务处理区域-----------//
	// 上下文关联、文件启动、错误保持和 FIFO 背压。
	always @(posedge i_clk or negedge i_rstn) begin
		if (i_rstn == 1'b0) begin
			assoc_index_q    <= 5'd0;
			assoc_count_q    <= 5'd0;
			assoc_ready_q    <= 1'b0;
			assoc_valid_q    <= 1'b0;
			open_index_q     <= 5'd0;
			parser_start_q   <= 1'b0;
			parser_start_pending_q <= 1'b0;
			parser_reset_q   <= 1'b0;
			fifo_flush_q     <= 1'b0;
			header_done_q    <= 1'b0;
			play_started_q   <= 1'b0;
			wav_done_q       <= 1'b0;
			reader_done_q    <= 1'b0;
			error_code_q     <= 8'd0;
			track_done_q     <= 1'b0;
			hold_high_q      <= 1'b0;
			pwm_enable_q     <= 1'b0;
			audio_error_o    <= 1'b0;
			audio_error_code_o <= 8'd0;
			audio_track_done_o <= 1'b0;
		end else begin
			parser_start_q     <= 1'b0;
			audio_track_done_o <= track_done_q;

			if (track_change_now) begin
				parser_reset_q   <= 1'b1;
				parser_start_pending_q <= 1'b1;
				assoc_index_q    <= i_image_index;
				assoc_count_q    <= i_audio_count;
				assoc_ready_q    <= i_audio_ready;
				assoc_valid_q    <= 1'b1;
				open_index_q     <= i_image_index;
				fifo_flush_q     <= 1'b1;
				header_done_q    <= 1'b0;
				play_started_q   <= 1'b0;
				wav_done_q       <= 1'b0;
				reader_done_q    <= 1'b0;
				error_code_q     <= 8'd0;
				hold_high_q      <= 1'b0;
				audio_error_o    <= 1'b0;
				audio_error_code_o <= 8'd0;
			end else if (open_accept) begin
				parser_reset_q   <= 1'b1;
				parser_start_pending_q <= 1'b1;
				fifo_flush_q     <= 1'b1;
				header_done_q    <= 1'b0;
				play_started_q   <= 1'b0;
				wav_done_q       <= 1'b0;
				reader_done_q    <= 1'b0;
				error_code_q     <= 8'd0;
				hold_high_q      <= 1'b0;
				audio_error_o    <= 1'b0;
				audio_error_code_o <= 8'd0;
			end else begin
				fifo_flush_q <= 1'b0;
				if (parser_start_pending_q) begin
					parser_reset_q <= 1'b0;
					parser_start_pending_q <= 1'b0;
					parser_start_q <= 1'b1;
				end else begin
					parser_reset_q <= 1'b0;
				end

				if ((state_current == ST_STREAM) && wav_header_done) begin
					header_done_q <= 1'b1;
				end
				if ((state_current == ST_STREAM) && wav_done) begin
					wav_done_q <= 1'b1;
				end
				if ((state_current == ST_STREAM) && i_reader_done) begin
					reader_done_q <= 1'b1;
				end
				if (((state_current == ST_STREAM) ||
				     (state_current == ST_DRAIN)) &&
				    header_done_q &&
				    !play_started_q &&
				    ((fifo_fill_level >= C_START_LEVEL) ||
				     (wav_done_q && (fifo_fill_level != 12'd0)))) begin
					play_started_q <= 1'b1;
				end
				if (fatal_error_now) begin
					fifo_flush_q     <= 1'b1;
					error_code_q     <= fatal_error_code;
					hold_high_q      <= 1'b1;
					audio_error_o    <= 1'b1;
					audio_error_code_o <= fatal_error_code;
				end
				if ((state_current == ST_DRAIN) &&
				    fifo_stream_done &&
				    (fifo_fill_level == 12'd0)) begin
					play_started_q <= 1'b0;
				end
				if ((state_current == ST_STREAM) && !fifo_flush_q) begin
					if (fifo_fill_level >= C_FIFO_HIGH_WATER) begin
						hold_high_q <= 1'b1;
					end else if (fifo_fill_level <= C_FIFO_LOW_WATER) begin
						hold_high_q <= 1'b0;
					end
				end
			end

			track_done_q <= (state_current == ST_DRAIN) &&
			                fifo_stream_done &&
			                (fifo_fill_level == 12'd0);
			pwm_enable_q <= pwm_enable_int;
		end
	end

	//------------模块实例化区域------------//
	// WAV 头解析器和 PCM 字节筛选。
	wav_header_parser u_wav_header_parser (
		.clk(i_clk),
		.rst_n(i_rstn && !parser_reset_q),
		.start(parser_start_q),
		.in_valid(wav_input_valid),
		.in_data(i_reader_byte_data),
		.in_last(i_reader_byte_last),
		.busy(wav_busy),
		.done(wav_done),
		.error(wav_error),
		.error_code(wav_error_code),
		.header_done(wav_header_done),
		.riff_size(),
		.data_offset(),
		.data_size(),
		.sample_rate(),
		.channels(),
		.bits_per_sample(),
		.byte_rate(),
		.block_align(),
		.pcm_valid(wav_pcm_valid),
		.pcm_data(wav_pcm_data),
		.pcm_last(wav_pcm_last)
	);

	// PCM 样本 FIFO、低水位和错误状态。
	audio_fifo #(
		.DEPTH(C_FIFO_DEPTH),
		.LOW_WATER(C_FIFO_LOW_WATER)
	) u_audio_fifo (
		.clk(i_clk),
		.rst_n(i_rstn),
		.flush(fifo_flush_q),
		.pcm_valid(wav_pcm_valid),
		.pcm_data(wav_pcm_data),
		.pcm_last(wav_pcm_last),
		.sample_tick(sample_tick_wire),
		.sample_out(fifo_sample_out),
		.sample_valid(fifo_sample_valid),
		.underrun(fifo_underrun),
		.low_water(fifo_low_water),
		.full(fifo_full),
		.overflow(fifo_overflow),
		.format_error(fifo_format_error),
		.stream_done(fifo_stream_done),
		.fill_level(fifo_fill_level)
	);

	// 固定 48 kHz 平均采样节拍。
	sample_rate_tick #(
		.CLK_HZ(C_CLOCK_HZ),
		.TICK_HZ(C_SAMPLE_HZ)
	) u_sample_rate_tick (
		.clk(i_clk),
		.rst_n(i_rstn),
		.enable(pwm_enable_int),
		.tick(sample_tick_wire)
	);

	// 有符号 PCM 到板卡 Audio_PWM。
	audio_pwm u_audio_pwm (
		.clk(i_clk),
		.rst_n(i_rstn),
		.sample_valid(pwm_sample_valid),
		.sample_pcm(pwm_sample_data),
		.underrun(fifo_underrun),
		.pwm_enable(pwm_enable_int),
		.audio_pwm(audio_pwm_o),
		.duty_debug(duty_debug_o)
	);

endmodule
