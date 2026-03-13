
module streaming_multiprocessor
  import edugpu_pkg::*;
#(
  parameter int SM_ID = 0
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic              dispatch_valid,
  input  logic [31:0]       dispatch_block_id,
  input  logic [31:0]       dispatch_kernel_pc,
  input  logic [31:0]       dispatch_thread_count,
  output logic              dispatch_ready,
  output logic              sm_done,              

  output mem_req_t          mem_req,
  input  mem_resp_t         mem_resp,


  output logic              imem_req_valid,
  output logic [31:0]       imem_req_addr,
  input  logic              imem_resp_valid,
  input  logic [31:0]       imem_resp_data,


  output warp_ctx_t         dbg_warp [0:WARPS_PER_SM-1]
);

  logic              sched_fetch_en;
  logic [1:0]        sched_fetch_warp;
  logic [31:0]       sched_fetch_pc [0:WARPS_PER_SM-1];

  logic              fetch_instr_valid;
  instr_t            fetch_instr;
  logic [31:0]       fetch_instr_pc;
  logic [1:0]        fetch_instr_warp;
  logic              fetch_stall;

  logic              decode_valid;
  decoded_instr_t    decode_instr;
  logic [31:0]       decode_pc;
  logic [1:0]        decode_warp;
  logic              decode_stall_fb;


  logic [31:0]       scoreboard [0:1];
  logic              sb_set_en;
  logic [1:0]        sb_set_warp;
  logic [4:0]        sb_set_reg;
  logic              sb_clr_en;
  logic [1:0]        sb_clr_warp;
  logic [4:0]        sb_clr_reg;

  logic [31:0]       rf_a [0:WARP_SIZE-1];
  logic [31:0]       rf_b [0:WARP_SIZE-1];


  logic              alu_result_valid;
  logic [1:0]        alu_result_warp;
  logic [4:0]        alu_result_reg;
  logic [31:0]       alu_result_data [0:WARP_SIZE-1];
  logic [WARP_SIZE-1:0] alu_result_mask;

  logic              branch_taken;
  logic [31:0]       branch_target;
  logic [1:0]        branch_warp;
  logic              sfu_busy;

  logic              ldst_result_valid;
  logic [1:0]        ldst_result_warp;
  logic [4:0]        ldst_result_reg;
  logic [31:0]       ldst_result_data [0:WARP_SIZE-1];
  logic [WARP_SIZE-1:0] ldst_result_mask;

  logic              ldst_stall;
  logic [1:0]        ldst_stall_warp;
  logic              ldst_resume;
  logic [1:0]        ldst_resume_warp;


  logic              wb_en;
  logic [1:0]        wb_warp;
  logic [4:0]        wb_reg;
  logic [31:0]       wb_data [0:WARP_SIZE-1];
  logic [WARP_SIZE-1:0] wb_mask;

  logic [31:0]       thread_ids [0:WARP_SIZE-1];
  logic [31:0]       block_id_reg;
  logic [31:0]       block_dim_reg;


  decoded_instr_t    dr_instr;   
  logic [31:0]       dr_pc;
  logic [1:0]        dr_warp;
  logic              dr_valid;

  decoded_instr_t    re_instr;   
  logic [31:0]       re_pc;
  logic [1:0]        re_warp;
  logic              re_valid;
  logic [31:0]       re_op_a [0:WARP_SIZE-1];
  logic [31:0]       re_op_b [0:WARP_SIZE-1];
  logic [WARP_SIZE-1:0] re_mask;


  always_comb begin
    block_id_reg  = dbg_warp[sched_fetch_warp].block_id;
    block_dim_reg = dispatch_thread_count;
    for (int t = 0; t < WARP_SIZE; t++) begin
      thread_ids[t] = dbg_warp[sched_fetch_warp].thread_id_base + t;
    end
  end


  warp_scheduler #(.SM_ID(SM_ID)) u_sched (
    .clk, .rst_n,
    .dispatch_valid,
    .dispatch_block_id,
    .dispatch_kernel_pc,
    .dispatch_thread_count,
    .dispatch_ready,
    .fetch_en         (sched_fetch_en),
    .fetch_warp       (sched_fetch_warp),
    .fetch_pc         (sched_fetch_pc),
    .decode_stall     (decode_stall_fb),
    .decode_warp      (decode_warp),
    .branch_taken,
    .branch_warp,
    .branch_target,
    .instr_issued     (fetch_instr_valid),
    .issued_warp      (fetch_instr_warp),
    .mem_stall        (ldst_stall),
    .mem_stall_warp   (ldst_stall_warp),
    .mem_resume       (ldst_resume),
    .mem_resume_warp  (ldst_resume_warp),
    .sync_reached     (re_valid && re_instr.is_sync),
    .sync_warp        (re_warp),
    .thread_exit      (re_valid && re_instr.is_exit),
    .exit_warp        (re_warp),
    .exit_mask        (re_mask),
    .warp_ctx         (dbg_warp),
    .all_warps_done   (sm_done)
  );


  fetch_unit u_fetch (
    .clk, .rst_n,
    .fetch_en         (sched_fetch_en),
    .warp_sel         (sched_fetch_warp),
    .warp_pc          (sched_fetch_pc),
    .branch_taken,
    .branch_warp,
    .branch_target,
    .imem_req_valid,
    .imem_req_addr,
    .imem_resp_valid,
    .imem_resp_data,
    .instr_valid      (fetch_instr_valid),
    .instr_out        (fetch_instr),
    .instr_pc_out     (fetch_instr_pc),
    .instr_warp_out   (fetch_instr_warp),
    .fetch_stall
  );

  assign fetch_stall = decode_stall_fb;


  decode_unit u_decode (
    .clk, .rst_n,
    .instr_valid_in   (fetch_instr_valid),
    .instr_in         (fetch_instr),
    .instr_pc_in      (fetch_instr_pc),
    .instr_warp_in    (fetch_instr_warp),
    .scoreboard,
    .decode_valid,
    .decoded_out      (decode_instr),
    .decode_pc,
    .decode_warp,
    .decode_stall     (decode_stall_fb),
    .sb_set_en,
    .sb_set_warp,
    .sb_set_reg,
    .sb_clr_en,
    .sb_clr_warp,
    .sb_clr_reg
  );


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dr_valid <= 1'b0;
    end else begin
      dr_valid  <= decode_valid;
      dr_instr  <= decode_instr;
      dr_pc     <= decode_pc;
      dr_warp   <= decode_warp;
    end
  end


  register_file u_rf (
    .clk, .rst_n,
   
    .rd_en_a          (dr_valid),
    .rd_reg_a         (dr_instr.rs1),
    .rd_thread_base_a (5'h0),       
    .rd_data_a        (rf_a),
  
    .rd_en_b          (dr_valid),
    .rd_reg_b         (dr_instr.rs2),
    .rd_thread_base_b (5'h0),
    .rd_data_b        (rf_b),
    
    .wr_en            (wb_en),
    .wr_reg           (wb_reg),
    .wr_thread_base   (5'h0),
    .wr_data          (wb_data),
    .wr_thread_mask   (wb_mask)
  );


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      re_valid <= 1'b0;
    end else begin
      re_valid <= dr_valid;
      re_instr <= dr_instr;
      re_pc    <= dr_pc;
      re_warp  <= dr_warp;
      re_mask  <= dbg_warp[dr_warp].active_mask[WARP_SIZE-1:0];

      for (int t = 0; t < WARP_SIZE; t++) begin
        re_op_a[t] <= rf_a[t];
      
        if (dr_instr.uses_imm)
          re_op_b[t] <= sign_ext11(dr_instr.imm);
        else
          re_op_b[t] <= rf_b[t];
      end
    end
  end

 
  alu_fpu_unit u_alu (
    .clk, .rst_n,
    .exec_valid       (re_valid && !re_instr.is_mem),
    .exec_instr       (re_instr),
    .exec_pc          (re_pc),
    .exec_warp        (re_warp),
    .exec_mask        (re_mask),
    .thread_ids,
    .block_id         (block_id_reg),
    .block_dim        (block_dim_reg),
    .op_a             (re_op_a),
    .op_b             (re_op_b),
    .result_valid     (alu_result_valid),
    .result_warp      (alu_result_warp),
    .result_reg       (alu_result_reg),
    .result_data      (alu_result_data),
    .result_mask      (alu_result_mask),
    .branch_taken,
    .branch_target,
    .branch_warp_out  (branch_warp),
    .sfu_busy
  );

 
  ldst_unit #(.SM_ID(SM_ID)) u_ldst (
    .clk, .rst_n,
    .ldst_valid       (re_valid && re_instr.is_mem),
    .ldst_instr       (re_instr),
    .ldst_warp        (re_warp),
    .ldst_mask        (re_mask),
    .ldst_addr        (re_op_a),   
    .ldst_wdata       (re_op_b),
    .gmem_req         (mem_req),
    .gmem_resp        (mem_resp),
    .ldst_result_valid,
    .ldst_result_warp,
    .ldst_result_reg,
    .ldst_result_data,
    .ldst_result_mask,
    .ldst_stall,
    .ldst_stall_warp,
    .ldst_resume,
    .ldst_resume_warp
  );


  always_comb begin
    if (ldst_result_valid) begin
      wb_en   = 1'b1;
      wb_warp = ldst_result_warp;
      wb_reg  = ldst_result_reg;
      wb_mask = ldst_result_mask;
      for (int t = 0; t < WARP_SIZE; t++)
        wb_data[t] = ldst_result_data[t];
    end else if (alu_result_valid) begin
      wb_en   = 1'b1;
      wb_warp = alu_result_warp;
      wb_reg  = alu_result_reg;
      wb_mask = alu_result_mask;
      for (int t = 0; t < WARP_SIZE; t++)
        wb_data[t] = alu_result_data[t];
    end else begin
      wb_en   = 1'b0;
      wb_warp = '0;
      wb_reg  = '0;
      wb_mask = '0;
      for (int t = 0; t < WARP_SIZE; t++)
        wb_data[t] = '0;
    end


    sb_clr_en   = wb_en;
    sb_clr_warp = wb_warp;
    sb_clr_reg  = wb_reg;
  end

endmodule