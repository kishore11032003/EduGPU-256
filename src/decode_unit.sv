// =============================================================================
// EduGPU-256 — Instruction Decode Unit
// File   : decode_unit.sv
// =============================================================================

module decode_unit
  import edugpu_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  logic              instr_valid_in,
  input  instr_t            instr_in,
  input  logic [31:0]       instr_pc_in,
  input  logic [1:0]        instr_warp_in,

  input  logic [31:0]       scoreboard [0:1],

  output logic              decode_valid,
  output decoded_instr_t    decoded_out,
  output logic [31:0]       decode_pc,
  output logic [1:0]        decode_warp,

  output logic              decode_stall,

  output logic              sb_set_en,
  output logic [1:0]        sb_set_warp,
  output logic [4:0]        sb_set_reg,

  input  logic              sb_clr_en,
  input  logic [1:0]        sb_clr_warp,
  input  logic [4:0]        sb_clr_reg
);

 
  // Scoreboard Register 

  logic [31:0] sb [0:1];
  logic        sb_clr_en_r,  sb_set_en_r;
  logic [1:0]  sb_clr_warp_r, sb_set_warp_r;
  logic [4:0]  sb_clr_reg_r,  sb_set_reg_r;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sb_clr_en_r   <= 1'b0; sb_set_en_r   <= 1'b0;
      sb_clr_warp_r <= '0;   sb_set_warp_r <= '0;
      sb_clr_reg_r  <= '0;   sb_set_reg_r  <= '0;
    end else begin
      sb_clr_en_r   <= sb_clr_en;   sb_clr_warp_r <= sb_clr_warp;
      sb_clr_reg_r  <= sb_clr_reg;
      sb_set_en_r   <= sb_set_en;   sb_set_warp_r <= sb_set_warp;
      sb_set_reg_r  <= sb_set_reg;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sb[0] <= '0;
      sb[1] <= '0;
    end else begin

      sb[0] <= (sb[0]
                & ~(sb_clr_en_r && !sb_clr_warp_r[0] ? 32'd1 << sb_clr_reg_r : 32'd0))
                |  (sb_set_en_r && !sb_set_warp_r[0] ? 32'd1 << sb_set_reg_r  : 32'd0);
      sb[1] <= (sb[1]
                & ~(sb_clr_en_r &&  sb_clr_warp_r[0] ? 32'd1 << sb_clr_reg_r : 32'd0))
                |  (sb_set_en_r &&  sb_set_warp_r[0] ? 32'd1 << sb_set_reg_r  : 32'd0);
    end
  end


  // Combinational Decode

  decoded_instr_t dec;
  opcode_t        op;
  logic           raw_hazard;
  logic           rs1_cleared, rs2_cleared; 
  always_comb begin
    dec            = '0;
    op             = OP_NOP;  
    sb_set_en      = 1'b0;
    sb_set_warp    = instr_warp_in;
    sb_set_reg     = '0;
    decode_stall   = 1'b0;
    decode_valid   = 1'b0;
    raw_hazard     = 1'b0;
    rs1_cleared    = 1'b0;
    rs2_cleared    = 1'b0;

    if (instr_valid_in) begin
      op         = get_opcode(instr_in);
      dec.opcode = op;
      dec.rd     = get_rd(instr_in);
      dec.rs1    = get_rs1(instr_in);
      dec.rs2    = get_rs2(instr_in);
      dec.imm    = get_imm(instr_in);
      rs1_cleared = sb_clr_en
                    && (sb_clr_warp == instr_warp_in)
                    && (sb_clr_reg  == dec.rs1);
      rs2_cleared = sb_clr_en
                    && (sb_clr_warp == instr_warp_in)
                    && (sb_clr_reg  == dec.rs2);
      case (op)
        OP_ADD, OP_SUB, OP_MUL,
        OP_AND, OP_OR,  OP_XOR,
        OP_SHL, OP_SHR: begin
          dec.is_fp    = 1'b0;
          dec.uses_imm = 1'b0;
        end

        OP_ADDI: begin
          dec.uses_imm = 1'b1;
        end

        OP_FADD, OP_FSUB, OP_FMUL, OP_FFMA: begin
          dec.is_fp    = 1'b1;
          dec.uses_imm = 1'b0;
        end

        OP_FRCP, OP_FSQRT, OP_FSIN, OP_FCOS: begin
          dec.is_fp    = 1'b1;
          dec.is_sfu   = 1'b1;
          dec.uses_imm = 1'b0;
        end

        OP_FCVT, OP_FCMP: begin
          dec.is_fp    = 1'b1;
        end

        OP_LDG: begin
          dec.is_mem   = 1'b1;
          dec.is_load  = 1'b1;
          dec.uses_imm = 1'b1;
        end
        OP_STG: begin
          dec.is_mem   = 1'b1;
          dec.is_store = 1'b1;
          dec.uses_imm = 1'b1;
        end

        OP_LDS: begin
          dec.is_mem    = 1'b1;
          dec.is_load   = 1'b1;
          dec.is_shmem  = 1'b1;
          dec.uses_imm  = 1'b1;
        end
        OP_STS: begin
          dec.is_mem    = 1'b1;
          dec.is_store  = 1'b1;
          dec.is_shmem  = 1'b1;
          dec.uses_imm  = 1'b1;
        end

        OP_LDC: begin
          dec.is_mem    = 1'b1;
          dec.is_load   = 1'b1;
          dec.uses_imm  = 1'b1;
        end

        OP_LDTEX: begin
          dec.is_mem    = 1'b1;
          dec.is_load   = 1'b1;
          dec.is_fp     = 1'b1;
        end

        OP_BRA: begin
          dec.is_branch = 1'b1;
          dec.uses_imm  = 1'b1;
        end
        OP_BEQ, OP_BNE, OP_BLT: begin
          dec.is_branch = 1'b1;
          dec.uses_imm  = 1'b1;
        end
        OP_CALL: begin
          dec.is_branch = 1'b1;
        end
        OP_RET: begin
          dec.is_branch = 1'b1;
        end

        OP_SYNC: begin
          dec.is_sync  = 1'b1;
        end
        OP_EXIT: begin
          dec.is_exit  = 1'b1;
        end

        OP_TIDI, OP_BIDX, OP_BDIM,
        OP_LANE, OP_WARPID: begin
          dec.is_special = 1'b1;
        end

        OP_NOP: begin end
        default: begin end
      endcase


      // RAW Hazard Detection 
 
      if (!dec.uses_imm) begin
        if ((sb[instr_warp_in[0]][dec.rs1] && !rs1_cleared) ||
            (sb[instr_warp_in[0]][dec.rs2] && !rs2_cleared))
          raw_hazard = 1'b1;
      end else begin
        if (sb[instr_warp_in[0]][dec.rs1] && !rs1_cleared)
          raw_hazard = 1'b1;
      end

      if (dec.is_store && sb[instr_warp_in[0]][dec.rs2] && !rs2_cleared)
        raw_hazard = 1'b1;

      // Output

      if (raw_hazard) begin
        decode_stall  = 1'b1;
        decode_valid  = 1'b0;
      end else begin
        decode_stall  = 1'b0;
        decode_valid  = 1'b1;

        if (!dec.is_store && !dec.is_branch &&
            !dec.is_sync  && !dec.is_exit   && (op != OP_NOP)) begin
          sb_set_en   = 1'b1;
          sb_set_warp = instr_warp_in;
          sb_set_reg  = dec.rd;
        end
      end
    end
  end


  // Pipeline Register
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      decoded_out  <= '0;
      decode_pc    <= '0;
      decode_warp  <= '0;
    end else if (!decode_stall && instr_valid_in) begin
      decoded_out  <= dec;
      decode_pc    <= instr_pc_in;
      decode_warp  <= instr_warp_in;
    end
  end

endmodule