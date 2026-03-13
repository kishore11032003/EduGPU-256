// =============================================================================
// EduGPU-256 — ALU / FPU Execution Unit
// File   : alu_fpu_unit.sv
// =============================================================================

module alu_fpu_unit
  import edugpu_pkg::*;
#(
  parameter int THREADS = WARP_SIZE
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic              exec_valid,
  input  decoded_instr_t    exec_instr,
  input  logic [31:0]       exec_pc,
  input  logic [1:0]        exec_warp,
  input  logic [THREADS-1:0] exec_mask,

  input  logic [31:0]       thread_ids   [0:THREADS-1],
  input  logic [31:0]       block_id,
  input  logic [31:0]       block_dim,

  input  logic [31:0]       op_a [0:THREADS-1],
  input  logic [31:0]       op_b [0:THREADS-1],

  output logic              result_valid,
  output logic [1:0]        result_warp,
  output logic [4:0]        result_reg,
  output logic [31:0]       result_data  [0:THREADS-1],
  output logic [THREADS-1:0] result_mask,

  output logic              branch_taken,
  output logic [31:0]       branch_target,
  output logic [1:0]        branch_warp_out,

  output logic              sfu_busy
);
 
  // INT32 ALU

  logic [31:0] alu_result [0:THREADS-1];

  always_comb begin
    for (int t = 0; t < THREADS; t++) begin
      case (exec_instr.opcode)
        OP_ADD, OP_ADDI : alu_result[t] = op_a[t] + op_b[t];
        OP_SUB          : alu_result[t] = op_a[t] - op_b[t];
        OP_MUL          : alu_result[t] = op_a[t] * op_b[t];
        OP_AND          : alu_result[t] = op_a[t] & op_b[t];
        OP_OR           : alu_result[t] = op_a[t] | op_b[t];
        OP_XOR          : alu_result[t] = op_a[t] ^ op_b[t];
        OP_SHL          : alu_result[t] = op_a[t] << op_b[t][4:0];
        OP_SHR          : alu_result[t] = op_a[t] >> op_b[t][4:0];
        default         : alu_result[t] = 32'h0;
      endcase
    end
  end

  // SFU (4-stage pipeline)

  logic [31:0] sfu_pipe      [0:3][0:THREADS-1];
  logic        sfu_valid_pipe[0:3];
  logic [4:0]  sfu_reg_pipe  [0:3];
  logic [1:0]  sfu_warp_pipe [0:3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s=0;s<4;s++) begin
        sfu_valid_pipe[s] <= 0;
        sfu_reg_pipe[s]   <= 0;
        sfu_warp_pipe[s]  <= 0;
        for (int t=0;t<THREADS;t++)
          sfu_pipe[s][t] <= 0;
      end
    end
    else begin

      for (int s=3;s>0;s--) begin
        sfu_valid_pipe[s] <= sfu_valid_pipe[s-1];
        sfu_reg_pipe[s]   <= sfu_reg_pipe[s-1];
        sfu_warp_pipe[s]  <= sfu_warp_pipe[s-1];

        for (int t=0;t<THREADS;t++)
          sfu_pipe[s][t] <= sfu_pipe[s-1][t];
      end

      sfu_valid_pipe[0] <= exec_valid && exec_instr.is_sfu;
      sfu_reg_pipe[0]   <= exec_instr.rd;
      sfu_warp_pipe[0]  <= exec_warp;

      if (exec_valid && exec_instr.is_sfu) begin
        for (int t=0;t<THREADS;t++) begin

          real fa;
          fa = f32_to_real(op_a[t]);

          case (exec_instr.opcode)
            OP_FRCP  : sfu_pipe[0][t] <= real_to_f32(1.0/fa);
            OP_FSQRT : sfu_pipe[0][t] <= real_to_f32($sqrt(fa));
            OP_FSIN  : sfu_pipe[0][t] <= real_to_f32($sin(fa));
            OP_FCOS  : sfu_pipe[0][t] <= real_to_f32($cos(fa));
            default  : sfu_pipe[0][t] <= 0;
          endcase

        end
      end

    end
  end

  assign sfu_busy = exec_valid && exec_instr.is_sfu;


  // THREAD METADATA

  logic [31:0] meta_result [0:THREADS-1];

  always_comb begin
    for (int t=0;t<THREADS;t++) begin
      case(exec_instr.opcode)
        OP_TIDI   : meta_result[t] = thread_ids[t];
        OP_BIDX   : meta_result[t] = block_id;
        OP_BDIM   : meta_result[t] = block_dim;
        OP_LANE   : meta_result[t] = t;
        OP_WARPID : meta_result[t] = 32'(exec_warp);
        default   : meta_result[t] = 0;
      endcase
    end
  end


  // BRANCH UNIT

  always_comb begin

    branch_taken    = 0;
    branch_target   = exec_pc;
    branch_warp_out = exec_warp;

    if (exec_valid) begin

      case(exec_instr.opcode)

        OP_BRA : begin
          branch_taken  = 1;
          branch_target = exec_pc + (sign_ext11(exec_instr.imm)<<2);
        end

        OP_BEQ : begin
          branch_taken  = (op_a[0] == op_b[0]);
          branch_target = exec_pc + (sign_ext11(exec_instr.imm)<<2);
        end

        OP_BNE : begin
          branch_taken  = (op_a[0] != op_b[0]);
          branch_target = exec_pc + (sign_ext11(exec_instr.imm)<<2);
        end

        OP_BLT : begin
          branch_taken  = ($signed(op_a[0]) < $signed(op_b[0]));
          branch_target = exec_pc + (sign_ext11(exec_instr.imm)<<2);
        end

        OP_CALL : begin
          branch_taken  = 1;
          branch_target = op_a[0];
        end

        OP_RET : begin
          branch_taken  = 1;
          branch_target = op_a[0];
        end

      endcase

    end

  end


  function automatic logic [31:0] compute_result(
    input decoded_instr_t instr,
    input int             lane,
    input logic [31:0]    a,
    input logic [31:0]    b,
    input logic [31:0]    meta,
    input logic [31:0]    alu
  );
    real fa, fb;
    fa = f32_to_real(a);
    fb = f32_to_real(b);
    case (instr.opcode)
      OP_FADD : return real_to_f32(fa + fb);
      OP_FSUB : return real_to_f32(fa - fb);
      OP_FMUL : return real_to_f32(fa * fb);
      OP_FFMA : return real_to_f32(fa * fb);
      OP_FCMP : begin
        case (instr.imm[1:0])
          2'b00: return {31'h0, fa == fb};
          2'b01: return {31'h0, fa <  fb};
          2'b10: return {31'h0, fa <= fb};
          2'b11: return {31'h0, fa != fb};
          default: return 32'h0;
        endcase
      end
      OP_FCVT : begin
        if (!instr.imm[0]) return real_to_f32(real'($signed(a)));
        else               return 32'(int'(fa));
      end
      OP_TIDI, OP_BIDX, OP_BDIM, OP_LANE, OP_WARPID : return meta;
      default : return alu;
    endcase
  endfunction


  // RESULT UNIT

  always_ff @(posedge clk or negedge rst_n) begin

    if(!rst_n) begin

      result_valid <= 0;
      result_warp  <= 0;
      result_reg   <= 0;
      result_mask  <= 0;

      for(int t=0;t<THREADS;t++)
        result_data[t] <= 0;

    end
    else begin

      result_valid <= exec_valid
                   && !exec_instr.is_sfu
                   && !exec_instr.is_mem
                   && !exec_instr.is_branch
                   && !exec_instr.is_sync
                   && !exec_instr.is_exit;

      result_warp <= exec_warp;
      result_reg  <= exec_instr.rd;
      result_mask <= exec_mask;

      begin : result_loop
        logic [31:0] tmp [0:THREADS-1];
        for (int t=0;t<THREADS;t++)
          tmp[t] = compute_result(exec_instr, t, op_a[t], op_b[t], meta_result[t], alu_result[t]);
        result_data <= tmp;
      end

    end
  end

endmodule