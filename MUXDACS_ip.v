// Pipelined ADRV9009 TX source mux for a 250 MHz DAC clock.
//
// Important: high-speed FPGA datapaths should use edge-triggered pipeline
// flip-flops, not transparent latches.  This implementation divides the
// BRAM -> gain -> phase rotation -> source mux path into short clocked stages.
//
// Pipeline latency from inputs to DATAIOut/DATAQOut: 7 DAC_CLK cycles.

`timescale 1 ns / 1 ps

module MUXDACS_ip #(
  parameter integer AMPLIFY_FRAC_BITS = 0
) (
  input  wire               ADC_CLK, 
  input  wire               DAC_CLK,
  output wire               DACen,
  input  wire               reset,
  input  wire [15:0]        amplify,
  input  wire               doppler_enable,
  input  wire [31:0]        doppler_phase_offset,
  input  wire signed [31:0] doppler_phase_step,
  input  wire [1:0]         DacSel,
  input  wire [31:0]        DATAI,
  input  wire [31:0]        DATAQ,
  input  wire [63:0]        Pattern,
  input  wire [31:0]        DATAIin,
  input  wire [31:0]        DATAQin,
  input  wire [31:0]        DATAIin2,
  input  wire [31:0]        DATAQin2,  
  output wire [31:0]        DATAIOut,
  output wire [31:0]        DATAIOut2,  
  input  wire               dac_dufin,
  input  wire               dac_en,
  output wire               dac_dufnout,
  output wire [31:0]        DATAQOut,
  output wire [31:0]        DATAQOut2
);

  // ADC_CLK remains only for packaged-interface compatibility.

  function signed [15:0] sat16;
    input signed [32:0] value;
    begin
      if (value > 33'sd32767)
        sat16 = 16'sh7fff;
      else if (value < -33'sd32768)
        sat16 = 16'sh8000;
      else
        sat16 = value[15:0];
    end
  endfunction

  // ------------------------------------------------------------------------
  // Slow control synchronization into DAC_CLK.
  // These software-controlled buses must remain stable for several DAC clocks.
  // For atomic run-time changes, add a request/acknowledge update handshake.
  // ------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) reg        dac_en_meta, dac_en_sync;
  (* ASYNC_REG = "TRUE" *) reg        doppler_enable_meta, doppler_enable_sync;
  reg [1:0]  dacsel_meta, dacsel_sync;
  reg [15:0] amplify_meta, amplify_sync;
  reg [31:0] phase_offset_meta, phase_offset_sync;
  reg signed [31:0] phase_step_meta, phase_step_sync;
  reg [63:0] pattern_meta, pattern_sync;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      dac_en_meta          <= 1'b0;
      dac_en_sync          <= 1'b0;
      doppler_enable_meta  <= 1'b0;
      doppler_enable_sync  <= 1'b0;
      dacsel_meta          <= 2'd0;
      dacsel_sync          <= 2'd0;
      amplify_meta         <= 16'd1;
      amplify_sync         <= 16'd1;
      phase_offset_meta    <= 32'd0;
      phase_offset_sync    <= 32'd0;
      phase_step_meta      <= 32'sd0;
      phase_step_sync      <= 32'sd0;
      pattern_meta         <= 64'd0;
      pattern_sync         <= 64'd0;
    end else begin
      dac_en_meta          <= dac_en;
      dac_en_sync          <= dac_en_meta;
      doppler_enable_meta  <= doppler_enable;
      doppler_enable_sync  <= doppler_enable_meta;
      dacsel_meta          <= DacSel;
      dacsel_sync          <= dacsel_meta;
      amplify_meta         <= amplify;
      amplify_sync         <= amplify_meta;
      phase_offset_meta    <= doppler_phase_offset;
      phase_offset_sync    <= phase_offset_meta;
      phase_step_meta      <= doppler_phase_step;
      phase_step_sync      <= phase_step_meta;
      pattern_meta         <= Pattern;
      pattern_sync         <= pattern_meta;
    end
  end

  // ------------------------------------------------------------------------
  // Doppler phase accumulator. There are two samples in every 32-bit word.
  // ------------------------------------------------------------------------
  reg signed [31:0] doppler_phase_acc;
  wire signed [31:0] phase_sample1_now = doppler_phase_acc + phase_step_sync;
  wire signed [31:0] phase_step_x2_now = phase_step_sync <<< 1;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      doppler_phase_acc <= $signed(doppler_phase_offset);
    end else if (!doppler_enable_sync) begin
      doppler_phase_acc <= $signed(phase_offset_sync);
    end else if ((dacsel_sync == 2'd1) && dac_en_sync) begin
      doppler_phase_acc <= doppler_phase_acc + phase_step_x2_now;
    end
  end

  // 1024-entry Q1.15 sine LUT. Four synchronous ROM copies provide four
  // independent reads per DAC clock and map cleanly to FPGA memory resources.
  // Copy sin_lut_q15_1024.mem into the Vivado project.
  (* rom_style = "block" *) reg signed [15:0] sin_rom_s0 [0:1023];
  (* rom_style = "block" *) reg signed [15:0] sin_rom_c0 [0:1023];
  (* rom_style = "block" *) reg signed [15:0] sin_rom_s1 [0:1023];
  (* rom_style = "block" *) reg signed [15:0] sin_rom_c1 [0:1023];
  initial begin
    $readmemh("sin_lut_q15_1024.mem", sin_rom_s0);
    $readmemh("sin_lut_q15_1024.mem", sin_rom_c0);
    $readmemh("sin_lut_q15_1024.mem", sin_rom_s1);
    $readmemh("sin_lut_q15_1024.mem", sin_rom_c1);
  end

  // ------------------------------------------------------------------------
  // Stage 1: input capture, gain DSPs, phase addresses, pattern DSPs.
  // ------------------------------------------------------------------------
  (* use_dsp = "yes" *) reg signed [32:0] s1_gain_i0, s1_gain_i1;
  (* use_dsp = "yes" *) reg signed [32:0] s1_gain_q0, s1_gain_q1;
  reg [9:0] s1_sin_addr0, s1_sin_addr1, s1_cos_addr0, s1_cos_addr1;
  reg [31:0] s1_dma_i, s1_dma_q,s1_dma2_i, s1_dma2_q;
  reg [31:0] s1_pattern_i, s1_pattern_q;
  wire signed [15:0] pattern_i1_now = $signed(DATAIin[23:16]) * $signed(pattern_sync[43:36]);
  wire signed [15:0] pattern_i0_now = $signed(DATAIin[7:0])   * $signed(pattern_sync[43:36]);
  wire signed [15:0] pattern_q1_now = $signed(DATAQin[23:16]) * $signed(pattern_sync[43:36]);
  wire signed [15:0] pattern_q0_now = $signed(DATAQin[7:0])   * $signed(pattern_sync[43:36]);
  reg [1:0]  s1_sel;
  reg        s1_en, s1_doppler;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s1_gain_i0    <= 33'sd0;
      s1_gain_i1    <= 33'sd0;
      s1_gain_q0    <= 33'sd0;
      s1_gain_q1    <= 33'sd0;
      s1_sin_addr0  <= 10'd0;
      s1_sin_addr1  <= 10'd0;
      s1_cos_addr0  <= 10'd256;
      s1_cos_addr1  <= 10'd256;
      s1_dma_i      <= 32'd0;
      s1_dma_q      <= 32'd0;
      s1_dma2_i      <= 32'd0;
      s1_dma2_q      <= 32'd0;      
      s1_pattern_i  <= 32'd0;
      s1_pattern_q  <= 32'd0;
      s1_sel        <= 2'd0;
      s1_en         <= 1'b0;
      s1_doppler    <= 1'b0;
    end else begin
      s1_gain_i0 <= $signed(DATAI[15:0])  * $signed({1'b0, amplify_sync});
      s1_gain_i1 <= $signed(DATAI[31:16]) * $signed({1'b0, amplify_sync});
      s1_gain_q0 <= $signed(DATAQ[15:0])  * $signed({1'b0, amplify_sync});
      s1_gain_q1 <= $signed(DATAQ[31:16]) * $signed({1'b0, amplify_sync});

      s1_sin_addr0 <= doppler_phase_acc[31:22];
      s1_sin_addr1 <= phase_sample1_now[31:22];
      s1_cos_addr0 <= doppler_phase_acc[31:22] + 10'd256;
      s1_cos_addr1 <= phase_sample1_now[31:22] + 10'd256;

      s1_dma_i <= DATAIin;
      s1_dma_q <= DATAQin;
      s1_dma2_i <= DATAIin2;
      s1_dma2_q <= DATAQin2;      
      s1_pattern_i <= {pattern_i1_now, pattern_i0_now};
      s1_pattern_q <= {pattern_q1_now, pattern_q0_now};
      s1_sel     <= dacsel_sync;
      s1_en      <= dac_en_sync;
      s1_doppler <= doppler_enable_sync;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 2: fixed-point gain scaling/saturation and synchronous LUT read.
  // The right shift is required: 16'h8000 represents gain 1.0 in Q1.15.
  // ------------------------------------------------------------------------
  reg signed [15:0] s2_amp_i0, s2_amp_i1, s2_amp_q0, s2_amp_q1;
  reg signed [15:0] s2_sin0, s2_sin1, s2_cos0, s2_cos1;
  reg [31:0] s2_dma_i, s2_dma_q,s2_dma2_i, s2_dma2_q, s2_pattern_i, s2_pattern_q;
  reg [1:0]  s2_sel;
  reg        s2_en, s2_doppler;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s2_amp_i0 <= 16'sd0; s2_amp_i1 <= 16'sd0;
      s2_amp_q0 <= 16'sd0; s2_amp_q1 <= 16'sd0;
      s2_sin0   <= 16'sd0; s2_sin1   <= 16'sd0;
      s2_cos0   <= 16'sd0; s2_cos1   <= 16'sd0;
      s2_dma_i  <= 32'd0;  s2_dma_q  <= 32'd0;
      s2_dma2_i  <= 32'd0;  s2_dma2_q  <= 32'd0;
      s2_pattern_i <= 32'd0; s2_pattern_q <= 32'd0;
      s2_sel <= 2'd0; s2_en <= 1'b0; s2_doppler <= 1'b0;
    end else begin
      s2_amp_i0 <= sat16(s1_gain_i0 >>> AMPLIFY_FRAC_BITS);
      s2_amp_i1 <= sat16(s1_gain_i1 >>> AMPLIFY_FRAC_BITS);
      s2_amp_q0 <= sat16(s1_gain_q0 >>> AMPLIFY_FRAC_BITS);
      s2_amp_q1 <= sat16(s1_gain_q1 >>> AMPLIFY_FRAC_BITS);

      s2_sin0 <= sin_rom_s0[s1_sin_addr0];
      s2_sin1 <= sin_rom_s1[s1_sin_addr1];
      s2_cos0 <= sin_rom_c0[s1_cos_addr0];
      s2_cos1 <= sin_rom_c1[s1_cos_addr1];
      s2_dma2_i <= s1_dma2_i; s2_dma2_q <= s1_dma2_q;
      s2_dma_i  <= s1_dma_i; s2_dma_q <= s1_dma_q;
      s2_pattern_i <= s1_pattern_i; s2_pattern_q <= s1_pattern_q;
      s2_sel <= s1_sel; s2_en <= s1_en; s2_doppler <= s1_doppler;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 3: registered DSP multipliers for complex rotation.
  // ------------------------------------------------------------------------
  (* use_dsp = "yes" *) reg signed [31:0] s3_i0_cos, s3_q0_sin;
  (* use_dsp = "yes" *) reg signed [31:0] s3_i0_sin, s3_q0_cos;
  (* use_dsp = "yes" *) reg signed [31:0] s3_i1_cos, s3_q1_sin;
  (* use_dsp = "yes" *) reg signed [31:0] s3_i1_sin, s3_q1_cos;
  reg signed [15:0] s3_amp_i0, s3_amp_i1, s3_amp_q0, s3_amp_q1;
  reg [31:0] s3_dma_i, s3_dma_q,s3_dma2_i, s3_dma2_q, s3_pattern_i, s3_pattern_q;
  reg [1:0]  s3_sel;
  reg        s3_en, s3_doppler;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s3_i0_cos <= 32'sd0; s3_q0_sin <= 32'sd0;
      s3_i0_sin <= 32'sd0; s3_q0_cos <= 32'sd0;
      s3_i1_cos <= 32'sd0; s3_q1_sin <= 32'sd0;
      s3_i1_sin <= 32'sd0; s3_q1_cos <= 32'sd0;
      s3_amp_i0 <= 16'sd0; s3_amp_i1 <= 16'sd0;
      s3_amp_q0 <= 16'sd0; s3_amp_q1 <= 16'sd0;
      s3_dma_i <= 32'd0; s3_dma_q <= 32'd0;
      s3_dma2_i <= 32'd0; s3_dma2_q <= 32'd0;
      s3_pattern_i <= 32'd0; s3_pattern_q <= 32'd0;
      s3_sel <= 2'd0; s3_en <= 1'b0; s3_doppler <= 1'b0;
    end else begin
      s3_i0_cos <= s2_amp_i0 * s2_cos0;
      s3_q0_sin <= s2_amp_q0 * s2_sin0;
      s3_i0_sin <= s2_amp_i0 * s2_sin0;
      s3_q0_cos <= s2_amp_q0 * s2_cos0;
      s3_i1_cos <= s2_amp_i1 * s2_cos1;
      s3_q1_sin <= s2_amp_q1 * s2_sin1;
      s3_i1_sin <= s2_amp_i1 * s2_sin1;
      s3_q1_cos <= s2_amp_q1 * s2_cos1;

      s3_amp_i0 <= s2_amp_i0; s3_amp_i1 <= s2_amp_i1;
      s3_amp_q0 <= s2_amp_q0; s3_amp_q1 <= s2_amp_q1;
      s3_dma_i <= s2_dma_i; s3_dma_q <= s2_dma_q;
      s3_dma2_i <= s2_dma2_i; s3_dma2_q <= s2_dma2_q;
      s3_pattern_i <= s2_pattern_i; s3_pattern_q <= s2_pattern_q;
      s3_sel <= s2_sel; s3_en <= s2_en; s3_doppler <= s2_doppler;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 4: complex add/subtract.
  // ------------------------------------------------------------------------
  reg signed [32:0] s4_i0_sum, s4_q0_sum, s4_i1_sum, s4_q1_sum;
  reg signed [15:0] s4_amp_i0, s4_amp_i1, s4_amp_q0, s4_amp_q1;
  reg [31:0] s4_dma_i, s4_dma_q,s4_dma2_i, s4_dma2_q, s4_pattern_i, s4_pattern_q;
  reg [1:0]  s4_sel;
  reg        s4_en, s4_doppler;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s4_i0_sum <= 33'sd0; s4_q0_sum <= 33'sd0;
      s4_i1_sum <= 33'sd0; s4_q1_sum <= 33'sd0;
      s4_amp_i0 <= 16'sd0; s4_amp_i1 <= 16'sd0;
      s4_amp_q0 <= 16'sd0; s4_amp_q1 <= 16'sd0;
      s4_dma_i <= 32'd0; s4_dma_q <= 32'd0;
      s4_dma2_i <= 32'd0; s4_dma2_q <= 32'd0;
      s4_pattern_i <= 32'd0; s4_pattern_q <= 32'd0;
      s4_sel <= 2'd0; s4_en <= 1'b0; s4_doppler <= 1'b0;
    end else begin
      s4_i0_sum <= $signed({s3_i0_cos[31], s3_i0_cos})
                 - $signed({s3_q0_sin[31], s3_q0_sin});
      s4_q0_sum <= $signed({s3_i0_sin[31], s3_i0_sin})
                 + $signed({s3_q0_cos[31], s3_q0_cos});
      s4_i1_sum <= $signed({s3_i1_cos[31], s3_i1_cos})
                 - $signed({s3_q1_sin[31], s3_q1_sin});
      s4_q1_sum <= $signed({s3_i1_sin[31], s3_i1_sin})
                 + $signed({s3_q1_cos[31], s3_q1_cos});

      s4_amp_i0 <= s3_amp_i0; s4_amp_i1 <= s3_amp_i1;
      s4_amp_q0 <= s3_amp_q0; s4_amp_q1 <= s3_amp_q1;
      s4_dma_i <= s3_dma_i; s4_dma_q <= s3_dma_q;
      s4_dma2_i <= s3_dma2_i; s4_dma2_q <= s3_dma2_q;
      s4_pattern_i <= s3_pattern_i; s4_pattern_q <= s3_pattern_q;
      s4_sel <= s3_sel; s4_en <= s3_en; s4_doppler <= s3_doppler;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 5: Q1.15 rotation scaling and saturation.
  // ------------------------------------------------------------------------
  reg signed [15:0] s5_rot_i0, s5_rot_i1, s5_rot_q0, s5_rot_q1;
  reg signed [15:0] s5_amp_i0, s5_amp_i1, s5_amp_q0, s5_amp_q1;
  reg [31:0] s5_dma_i, s5_dma_q,s5_dma2_i, s5_dma2_q, s5_pattern_i, s5_pattern_q;
  reg [1:0]  s5_sel;
  reg        s5_en, s5_doppler;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s5_rot_i0 <= 16'sd0; s5_rot_i1 <= 16'sd0;
      s5_rot_q0 <= 16'sd0; s5_rot_q1 <= 16'sd0;
      s5_amp_i0 <= 16'sd0; s5_amp_i1 <= 16'sd0;
      s5_amp_q0 <= 16'sd0; s5_amp_q1 <= 16'sd0;
      s5_dma_i <= 32'd0; s5_dma_q <= 32'd0;
      s5_pattern_i <= 32'd0; s5_pattern_q <= 32'd0;
      s5_sel <= 2'd0; s5_en <= 1'b0; s5_doppler <= 1'b0;
    end else begin
      s5_rot_i0 <= sat16(s4_i0_sum >>> 15);
      s5_rot_q0 <= sat16(s4_q0_sum >>> 15);
      s5_rot_i1 <= sat16(s4_i1_sum >>> 15);
      s5_rot_q1 <= sat16(s4_q1_sum >>> 15);

      s5_amp_i0 <= s4_amp_i0; s5_amp_i1 <= s4_amp_i1;
      s5_amp_q0 <= s4_amp_q0; s5_amp_q1 <= s4_amp_q1;
      s5_dma_i <= s4_dma_i; s5_dma_q <= s4_dma_q;
      s5_dma2_i <= s4_dma2_i; s5_dma2_q <= s4_dma2_q;
      s5_pattern_i <= s4_pattern_i; s5_pattern_q <= s4_pattern_q;
      s5_sel <= s4_sel; s5_en <= s4_en; s5_doppler <= s4_doppler;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 6: Doppler bypass selection and word packing.
  // ------------------------------------------------------------------------
  reg [31:0] s6_processed_i, s6_processed_q;
  reg [31:0] s6_dma_i, s6_dma_q, s6_pattern_i, s6_pattern_q,s6_dma2_i, s6_dma2_q;
  reg [1:0]  s6_sel;
  reg        s6_en;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      s6_processed_i <= 32'd0;
      s6_processed_q <= 32'd0;
      s6_dma_i <= 32'd0; s6_dma_q <= 32'd0;
      s6_dma2_i <= 32'd0; s6_dma2_q <= 32'd0;
      s6_pattern_i <= 32'd0; s6_pattern_q <= 32'd0;
      s6_sel <= 2'd0; s6_en <= 1'b0;
    end else begin
      if (s5_doppler) begin
        s6_processed_i <= {s5_rot_i1, s5_rot_i0};
        s6_processed_q <= {s5_rot_q1, s5_rot_q0};
      end else begin
        s6_processed_i <= {s5_amp_i1, s5_amp_i0};
        s6_processed_q <= {s5_amp_q1, s5_amp_q0};
      end

      s6_dma_i <= s5_dma_i; s6_dma_q <= s5_dma_q;
      s6_dma2_i <= s5_dma2_i; s6_dma2_q <= s5_dma2_q;
      s6_pattern_i <= s5_pattern_i; s6_pattern_q <= s5_pattern_q;
      s6_sel <= s5_sel; s6_en <= s5_en;
    end
  end

  // ------------------------------------------------------------------------
  // Stage 7: final registered source mux.
  // ------------------------------------------------------------------------
  reg [31:0] data_i_out_reg, data_q_out_reg,data2_i_out_reg, data2_q_out_reg;

  always @(posedge DAC_CLK) begin
    if (reset) begin
      data_i_out_reg <= 32'd0;
      data_q_out_reg <= 32'd0;
      data2_i_out_reg <= 32'd0;
      data2_q_out_reg <= 32'd0;      
    end else begin
      case (s6_sel)
        2'd0: begin
          data_i_out_reg <= s6_dma_i;
          data_q_out_reg <= s6_dma_q;
          data2_i_out_reg <= s6_dma2_i;
          data2_q_out_reg <= s6_dma2_q;          
        end
        2'd1: begin
          if (s6_en) begin
            data_i_out_reg <= s6_processed_i;
            data_q_out_reg <= s6_processed_q;
            data2_i_out_reg <= s6_processed_i;
            data2_q_out_reg <= s6_processed_q;            
          end else begin
            data_i_out_reg <= 32'd0;
            data_q_out_reg <= 32'd0;
            data2_i_out_reg <= 32'd0;
            data2_q_out_reg <= 32'd0;            
          end
        end
        2'd2: begin
          data_i_out_reg <= s6_pattern_i;
          data_q_out_reg <= s6_pattern_q;
          data2_i_out_reg <= s6_pattern_i;
          data2_q_out_reg <= s6_pattern_q;          
        end
        default: begin
          data_i_out_reg <= s6_dma_i;
          data_q_out_reg <= s6_dma_q;
          data2_i_out_reg <= s6_dma2_i;
          data2_q_out_reg <= s6_dma2_q;          
        end
      endcase
    end
  end

  assign DATAIOut = data_i_out_reg;
  assign DATAQOut = data_q_out_reg;
  assign DATAIOut2 = data2_i_out_reg;
  assign DATAQOut2 = data2_q_out_reg;  

  assign DACen = (dacsel_sync == 2'd1) && dac_en_sync;
  assign dac_dufnout = ((dacsel_sync == 2'd0) || (dacsel_sync == 2'd3))
                       ? dac_dufin : ~dac_en_sync;

endmodule
