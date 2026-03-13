module warp_scheduler
  import edugpu_pkg::*;
#(
  parameter int SM_ID     = 0,
  parameter int NUM_WARPS = WARPS_PER_SM
) (
  input  logic              clk, rst_n,
  input  logic              dispatch_valid,
  input  logic [31:0]       dispatch_block_id, dispatch_kernel_pc, dispatch_thread_count,
  output logic              dispatch_ready,
  output logic              fetch_en,
  output logic [1:0]        fetch_warp,
  output logic [31:0]       fetch_pc [0:NUM_WARPS-1],
  input  logic              decode_stall,
  input  logic [1:0]        decode_warp,
  input  logic              branch_taken,
  input  logic [1:0]        branch_warp,
  input  logic [31:0]       branch_target,
  input  logic              instr_issued,
  input  logic [1:0]        issued_warp,
  input  logic              mem_stall,
  input  logic [1:0]        mem_stall_warp,
  input  logic              mem_resume,
  input  logic [1:0]        mem_resume_warp,
  input  logic              sync_reached,
  input  logic [1:0]        sync_warp,
  input  logic              thread_exit,
  input  logic [1:0]        exit_warp,
  input  logic [WARP_SIZE-1:0] exit_mask,
  output warp_ctx_t         warp_ctx [0:NUM_WARPS-1],
  output logic              all_warps_done
);

  warp_ctx_t warp [0:NUM_WARPS-1];
  logic [0:0] rr_ptr;
  logic [NUM_WARPS-1:0] barrier_arrived;
  logic [NUM_WARPS-1:0] issue_eligible;

  // --- Negedge-registered inputs (Verilator TB timing fix) ---
  logic              dispatch_valid_r;
  logic [31:0]       dispatch_block_id_r, dispatch_kernel_pc_r, dispatch_thread_count_r;
  logic              instr_issued_r;
  logic [1:0]        issued_warp_r;
  logic              mem_stall_r, mem_resume_r;
  logic [1:0]        mem_stall_warp_r, mem_resume_warp_r;
  logic              sync_reached_r;
  logic [1:0]        sync_warp_r;
  logic              thread_exit_r;
  logic [1:0]        exit_warp_r;
  logic [WARP_SIZE-1:0] exit_mask_r;
  logic              branch_taken_r;
  logic [1:0]        branch_warp_r;
  logic [31:0]       branch_target_r;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dispatch_valid_r <= 0; dispatch_block_id_r <= 0;
      dispatch_kernel_pc_r <= 0; dispatch_thread_count_r <= 0;
      instr_issued_r <= 0; issued_warp_r <= 0;
      mem_stall_r <= 0; mem_stall_warp_r <= 0;
      mem_resume_r <= 0; mem_resume_warp_r <= 0;
      sync_reached_r <= 0; sync_warp_r <= 0;
      thread_exit_r <= 0; exit_warp_r <= 0; exit_mask_r <= 0;
      branch_taken_r <= 0; branch_warp_r <= 0; branch_target_r <= 0;
    end else begin
      dispatch_valid_r <= dispatch_valid;
      dispatch_block_id_r <= dispatch_block_id;
      dispatch_kernel_pc_r <= dispatch_kernel_pc;
      dispatch_thread_count_r <= dispatch_thread_count;
      instr_issued_r <= instr_issued;
      issued_warp_r <= issued_warp;
      mem_stall_r <= mem_stall;
      mem_stall_warp_r <= mem_stall_warp;
      mem_resume_r <= mem_resume;
      mem_resume_warp_r <= mem_resume_warp;
      sync_reached_r <= sync_reached;
      sync_warp_r <= sync_warp;
      thread_exit_r <= thread_exit;
      exit_warp_r <= exit_warp;
      exit_mask_r <= exit_mask;
      branch_taken_r <= branch_taken;
      branch_warp_r <= branch_warp;
      branch_target_r <= branch_target;
    end
  end

  // --- Eligibility ---
  always_comb begin
    for (int w = 0; w < NUM_WARPS; w++)
      issue_eligible[w] = (warp[w[0]].state == WARP_READY || warp[w[0]].state == WARP_RUNNING)
                          && !(decode_stall && decode_warp == w[0:0])
                          && (warp[w[0]].active_mask != '0);
  end

  // --- Warp selection ---
  always_comb begin
    fetch_en = 0; fetch_warp = 0;
    if      (issue_eligible[rr_ptr])  begin fetch_en=1; fetch_warp={1'b0,rr_ptr}; end
    else if (issue_eligible[~rr_ptr]) begin fetch_en=1; fetch_warp={1'b0,~rr_ptr}; end
  end

  // --- State machine ---
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int w = 0; w < NUM_WARPS; w++) begin
        warp[w[0]].state <= WARP_IDLE; warp[w[0]].pc <= 0;
        warp[w[0]].active_mask <= 0; warp[w[0]].stall_mask <= 0;
        warp[w[0]].scoreboard <= 0; warp[w[0]].block_id <= 0;
        warp[w[0]].thread_id_base <= 0;
      end
      rr_ptr <= 0; barrier_arrived <= 0;
      dispatch_ready <= 1; all_warps_done <= 0;
    end else begin

      // 1. Dispatch — clears all_warps_done when new block accepted
      if (dispatch_valid_r && dispatch_ready) begin
        all_warps_done <= 0;
        warp[0].state <= WARP_READY; warp[0].pc <= dispatch_kernel_pc_r;
        warp[0].block_id <= dispatch_block_id_r;
        warp[0].thread_id_base <= dispatch_block_id_r * dispatch_thread_count_r;
        warp[0].active_mask <= {WARP_SIZE{1'b1}};
        warp[0].stall_mask <= 0; warp[0].scoreboard <= 0;

        warp[1].state <= (dispatch_thread_count_r > 32) ? WARP_READY : WARP_IDLE;
        warp[1].pc <= dispatch_kernel_pc_r;
        warp[1].block_id <= dispatch_block_id_r;
        warp[1].thread_id_base <= dispatch_block_id_r * dispatch_thread_count_r + 32;
        warp[1].active_mask <= (dispatch_thread_count_r > 32) ? {WARP_SIZE{1'b1}} : '0;
        warp[1].stall_mask <= 0; warp[1].scoreboard <= 0;
        dispatch_ready <= 0; barrier_arrived <= 0;
      end

      // 2. PC advance
      if (instr_issued_r) begin
        warp[issued_warp_r[0]].pc <= warp[issued_warp_r[0]].pc + 4;
        warp[issued_warp_r[0]].state <= WARP_RUNNING;
        rr_ptr <= ~rr_ptr;
      end

      // 3. Branch
      if (branch_taken_r) begin
        warp[branch_warp_r[0]].pc <= branch_target_r;
        warp[branch_warp_r[0]].state <= WARP_READY;
      end

      // 4. Mem stall
      if (mem_stall_r) warp[mem_stall_warp_r[0]].state <= WARP_STALL;

      // 5. Mem resume
      if (mem_resume_r) warp[mem_resume_warp_r[0]].state <= WARP_READY;

      // 6. Sync barrier
      if (sync_reached_r) begin
        warp[sync_warp_r[0]].state <= WARP_BARRIER;
        barrier_arrived[sync_warp_r[0]] <= 1;
      end
      if (barrier_arrived == ((1 << NUM_WARPS) - 1)) begin
        barrier_arrived <= 0;
        for (int w = 0; w < NUM_WARPS; w++)
          if (warp[w[0]].state == WARP_BARRIER) warp[w[0]].state <= WARP_READY;
      end

      // 7. Thread exit
      if (thread_exit_r) begin
        warp[exit_warp_r[0]].active_mask <= warp[exit_warp_r[0]].active_mask & ~exit_mask_r;
        if ((warp[exit_warp_r[0]].active_mask & ~exit_mask_r) == 0)
          warp[exit_warp_r[0]].state <= WARP_DONE;
      end

      // 8. All done
      begin
        automatic logic all_done = 1;
        for (int w = 0; w < NUM_WARPS; w++)
          if (warp[w[0]].state != WARP_DONE && warp[w[0]].state != WARP_IDLE) all_done = 0;
        if (all_done && !dispatch_ready) begin
          all_warps_done <= 1; dispatch_ready <= 1;
          for (int w = 0; w < NUM_WARPS; w++) warp[w[0]].state <= WARP_IDLE;
        end
      end
    end
  end

  always_comb begin
    for (int w = 0; w < NUM_WARPS; w++) begin
      warp_ctx[w] = warp[w[0]]; fetch_pc[w[0]] = warp[w[0]].pc;
    end
  end

endmodule