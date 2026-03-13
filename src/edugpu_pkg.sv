`timescale 1ns/1ps

package edugpu_pkg;

  typedef logic [31:0] instr_t;

 
  localparam int NUM_SMS        = 8;
  localparam int VRAM_ADDR_BITS = 31;

  
  localparam int L1_WAYS       = 4;
  localparam int L1_LINE_BYTES = 16;   
  localparam int L1_SETS       = 256;  


  localparam int L2_WAYS       = 8;
  localparam int L2_LINE_BYTES = 16;   
  localparam int L2_SETS       = 8192;

  typedef enum logic [1:0] {
    MEM_LOAD  = 2'b00,
    MEM_STORE = 2'b01,
    MEM_ATOMIC= 2'b10,
    MEM_FENCE = 2'b11
  } mem_op_t;

  typedef struct packed {
    logic                      valid;
    mem_op_t                   op;
    logic [3:0]                sm_id;
    logic [1:0]                warp_id;
    logic [4:0]                reg_dst;
    logic [VRAM_ADDR_BITS-1:0] addr;
    logic [31:0]               data;
    logic [3:0]                byte_en;
  } mem_req_t;

  typedef struct packed {
    logic        valid;
    logic [3:0]  sm_id;
    logic [1:0]  warp_id;
    logic [4:0]  reg_dst;
    logic [31:0] data;
    logic        error;
  } mem_resp_t;


  typedef enum logic [5:0] {
    OP_ADD   = 6'd0,
    OP_SUB   = 6'd1,
    OP_AND   = 6'd2,
    OP_OR    = 6'd3,
    OP_XOR   = 6'd4,
    OP_SHL   = 6'd5,
    OP_SHR   = 6'd6,
    OP_MUL   = 6'd7,
    OP_DIV   = 6'd8,
    OP_MOD   = 6'd9,
    OP_FADD  = 6'd10,
    OP_FSUB  = 6'd11,
    OP_FMUL  = 6'd12,
    OP_FFMA  = 6'd13,
    OP_FCMP  = 6'd14,
    OP_FRCP  = 6'd15,
    OP_FSQRT = 6'd16,
    OP_FSIN  = 6'd17,
    OP_FCOS  = 6'd18,
    OP_TIDI  = 6'd19,
    OP_BLKID = 6'd20,
    OP_WARPID= 6'd21,
    OP_BEQ   = 6'd22,
    OP_BNE   = 6'd23,
    OP_LDS   = 6'd24,
    OP_STS   = 6'd25,
    OP_LDG   = 6'd26,
    OP_STG   = 6'd27,
    OP_LDC   = 6'd28,
    OP_ADDI  = 6'd29,
    OP_FCVT  = 6'd30,
    OP_BIDX  = 6'd31,
    OP_BDIM  = 6'd32,
    OP_LANE  = 6'd33,
    OP_BRA   = 6'd34,
    OP_BLT   = 6'd35,
    OP_CALL  = 6'd36,
    OP_RET   = 6'd37,
    OP_LDTEX = 6'd38,
    OP_SYNC  = 6'd39,
    OP_EXIT  = 6'd40,
    OP_NOP   = 6'd63
  } opcode_t;

  typedef struct packed {
    opcode_t     opcode;
    logic [4:0]  rd, rs1, rs2;
    logic [10:0] imm;
    logic        is_fp, is_sfu, is_special, is_branch, is_mem;
    logic        is_load, is_store, is_shmem, uses_imm;
    logic        is_sync, is_exit;
  } decoded_instr_t;

  localparam int WARPS_PER_SM = 2;
  localparam int WARP_SIZE    = 32;
  localparam int SHMEM_BYTES  = 65536; 
  localparam int SHMEM_BANKS  = 32;

  typedef enum logic [2:0] {
    WARP_IDLE    = 3'd0,
    WARP_READY   = 3'd1,
    WARP_RUNNING = 3'd2,
    WARP_STALL   = 3'd3,
    WARP_BARRIER = 3'd4,
    WARP_DONE    = 3'd5
  } warp_state_t;

  typedef struct packed {
    warp_state_t          state;
    logic [31:0]          pc;
    logic [31:0]          active_mask;
    logic [31:0]          stall_mask;
    logic [31:0]          scoreboard;
    logic [31:0]          block_id;
    logic [31:0]          thread_id_base;
  } warp_ctx_t;


  function automatic opcode_t get_opcode(input instr_t instr);
    return opcode_t'(instr[31:26]);
  endfunction

  function automatic logic [4:0] get_rd(input instr_t instr);
    return instr[25:21];
  endfunction

  function automatic logic [4:0] get_rs1(input instr_t instr);
    return instr[20:16];
  endfunction

  function automatic logic [4:0] get_rs2(input instr_t instr);
    return instr[15:11];
  endfunction

  function automatic logic [10:0] get_imm(input instr_t instr);
    return instr[10:0];
  endfunction

  // Sign-extend 11-bit immediate to 32-bit
  function automatic logic [31:0] sign_ext11(input logic [10:0] imm);
    return {{21{imm[10]}}, imm};
  endfunction



  function automatic real f32_to_real(input logic [31:0] b);
    logic        s;
    logic [7:0]  e;
    logic [22:0] m;
    logic [10:0] e64;
    logic [51:0] m64;
    logic [63:0] d;
    s = b[31]; e = b[30:23]; m = b[22:0];
    if (e == 8'hFF) begin
      e64 = 11'h7FF; m64 = {m, 29'h0};
    end else if (e == 8'h00) begin
      e64 = 0; m64 = 0;
    end else begin
      e64 = {3'b000, e} - 11'd127 + 11'd1023;
      m64 = {m, 29'h0};
    end
    d = {s, e64, m64};
    return $bitstoreal(d);
  endfunction

  function automatic logic [31:0] real_to_f32(input real v);
    logic [63:0] d;
    logic        s;
    logic [10:0] e64;
    logic [51:0] m64;
    logic [7:0]  e32;
    logic [22:0] m32;
    int          exp;
    d   = $realtobits(v);
    s   = d[63]; e64 = d[62:52]; m64 = d[51:0];
    if (e64 == 11'h7FF) begin
      e32 = 8'hFF; m32 = m64[51:29];
    end else if (e64 == 0) begin
      e32 = 0; m32 = 0;
    end else begin
      exp = int'(e64) - 1023 + 127;
      if (exp >= 255) begin e32 = 8'hFF; m32 = 0; end
      else if (exp <= 0) begin e32 = 0; m32 = 0; end
      else begin e32 = exp[7:0]; m32 = m64[51:29]; end
    end
    return {s, e32, m32};
  endfunction

 
  localparam int CORES_PER_SM  = WARP_SIZE;
  localparam int L1_SIZE_BYTES = L1_WAYS * L1_SETS  * L1_LINE_BYTES; 
  localparam int L2_SIZE_BYTES = L2_WAYS * L2_SETS  * L2_LINE_BYTES; 
  localparam int CLK_FREQ_MHZ  = 500;                                 

  typedef struct packed {
    logic signed [15:0] x, y;  
    logic        [15:0] z;      
    logic        [7:0]  r, g, b;
    logic        [7:0]  u, v;
  } vertex_t;

  typedef struct packed {
    logic        [9:0]  x, y;   
    logic        [15:0] z;      
    
    logic        [7:0]  r, g, b, a;
    logic        [7:0]  u, v;
    logic               valid;
  } fragment_t;

endpackage