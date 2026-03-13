

module vram_controller
  import edugpu_pkg::*;
#(
  parameter int ADDR_BITS    = VRAM_ADDR_BITS, // 31 bits → 2 GB
  parameter int DATA_BITS    = 128,            // 128-bit bus
  parameter int NUM_BANKS    = 4,
  parameter int ROW_BITS     = 14,             // 16384 rows per bank
  parameter int COL_BITS     = 10,             // 1024 columns per row
  parameter int QUEUE_DEPTH  = 8,

  // DRAM timing (in clock cycles @ 500 MHz)
  parameter int tCL           = 4,
  parameter int tRCD          = 4,
  parameter int tRP           = 4,
  parameter int tRAS          = 10,
  parameter int tWR           = 4,
  parameter int tREFI         = 3900,
  parameter int tRFC          = 20
) (
  input  logic              clk,
  input  logic              rst_n,

  // ---- Request Interface (from L2 cache + ROPs) ----
  input  logic              req_valid,
  input  logic              req_wr,            // 1=write, 0=read
  input  logic [ADDR_BITS-1:0] req_addr,
  input  logic [DATA_BITS-1:0] req_wdata,
  input  logic [DATA_BITS/8-1:0] req_byte_en, // 16-bit byte enable
  input  logic [3:0]        req_tag,           // requester tag (returned with response)
  output logic              req_ready,         // controller can accept request

  // ---- Response Interface ----
  output logic              resp_valid,
  output logic [DATA_BITS-1:0] resp_rdata,
  output logic [3:0]        resp_tag,

  // ---- Physical DRAM Pins (simulation model — real I/O in FPGA) ----
  output logic              dram_cke,          // clock enable
  output logic              dram_cs_n,         // chip select
  output logic              dram_ras_n,        // row address strobe
  output logic              dram_cas_n,        // column address strobe
  output logic              dram_we_n,         // write enable
  output logic [1:0]        dram_ba,           // bank address
  output logic [ROW_BITS-1:0] dram_addr,       // row/column address
  output logic [DATA_BITS-1:0] dram_dq_out,    // data output
  input  logic [DATA_BITS-1:0] dram_dq_in,     // data input
  output logic [DATA_BITS/8-1:0] dram_dm,      // data mask

  // ---- Performance Counters ----
  output logic [31:0]       perf_reads,
  output logic [31:0]       perf_writes,
  output logic [31:0]       perf_refreshes,
  output logic [31:0]       perf_row_hits,
  output logic [31:0]       perf_row_misses
);

  // ---------------------------------------------------------------------------
  // Address Decomposition
  // Physical address → bank, row, column
  // addr[9:0]   = column (1024 cols × 16 bytes = 16 KB per row)
  // addr[23:10] = row    (14-bit → 16384 rows)
  // addr[25:24] = bank   (4 banks)
  // ---------------------------------------------------------------------------
  localparam int BYTE_BITS  = $clog2(DATA_BITS/8);  // 4 bits (16 bytes per beat)
  localparam int BANK_SHIFT = COL_BITS + BYTE_BITS;
  localparam int ROW_SHIFT  = BANK_SHIFT + $clog2(NUM_BANKS);

  function automatic logic [1:0] addr_bank(input logic [ADDR_BITS-1:0] a);
    return a[BANK_SHIFT + $clog2(NUM_BANKS) - 1 : BANK_SHIFT];
  endfunction
  function automatic logic [ROW_BITS-1:0] addr_row(input logic [ADDR_BITS-1:0] a);
    return a[ROW_SHIFT + ROW_BITS - 1 : ROW_SHIFT];
  endfunction
  function automatic logic [COL_BITS-1:0] addr_col(input logic [ADDR_BITS-1:0] a);
    return a[COL_BITS + BYTE_BITS - 1 : BYTE_BITS];
  endfunction

  // ---------------------------------------------------------------------------
  // Request Queue (FIFO depth 8)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                    wr;
    logic [ADDR_BITS-1:0]    addr;
    logic [DATA_BITS-1:0]    wdata;
    logic [DATA_BITS/8-1:0]  byte_en;
    logic [3:0]              tag;
  } dram_req_t;

  dram_req_t  queue      [0:QUEUE_DEPTH-1];
  logic [2:0] q_head, q_tail;
  logic [3:0] q_count;   // 0..8

  wire  q_full  = (q_count == QUEUE_DEPTH);
  wire  q_empty = (q_count == 0);

  assign req_ready = !q_full;

  // Enqueue merged into main FSM always_ff below (single driver for q_count).

  // ---------------------------------------------------------------------------
  // Negedge Request Capture — TB drives req_valid at negedge and deasserts at
  // the following posedge (race with DUT sample). Capture at negedge so the
  // posedge FSM always sees a stable, settled copy.
  // ---------------------------------------------------------------------------
  logic              req_valid_r;
  logic              req_wr_r;
  logic [ADDR_BITS-1:0] req_addr_r;
  logic [DATA_BITS-1:0] req_wdata_r;
  logic [DATA_BITS/8-1:0] req_byte_en_r;
  logic [3:0]        req_tag_r;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_valid_r <= 1'b0;
    end else begin
      req_valid_r   <= req_valid;
      req_wr_r      <= req_wr;
      req_addr_r    <= req_addr;
      req_wdata_r   <= req_wdata;
      req_byte_en_r <= req_byte_en;
      req_tag_r     <= req_tag;
    end
  end

  // ---------------------------------------------------------------------------
  // Per-Bank State: tracks open row (row buffer management)
  // ---------------------------------------------------------------------------
  logic [ROW_BITS-1:0] open_row  [0:NUM_BANKS-1]; // currently open row per bank
  logic                row_open  [0:NUM_BANKS-1]; // is a row open?
  logic [4:0]          bank_timer[0:NUM_BANKS-1]; // tRAS countdown

  // ---------------------------------------------------------------------------
  // Refresh Counter
  // ---------------------------------------------------------------------------
  logic [11:0] refresh_counter;  // counts up to tREFI
  logic        refresh_needed;
  logic        refresh_in_progress;
  logic [4:0]  refresh_timer;    // tRFC countdown

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      refresh_counter      <= '0;
      refresh_needed       <= 1'b0;
      refresh_in_progress  <= 1'b0;
      refresh_timer        <= '0;
    end else begin
      if (refresh_counter >= tREFI) begin
        refresh_counter <= '0;
        refresh_needed  <= 1'b1;
      end else begin
        refresh_counter <= refresh_counter + 12'd1;
      end

      if (refresh_in_progress) begin
        if (refresh_timer > 0)
          refresh_timer <= refresh_timer - 5'd1;
        else begin
          refresh_in_progress <= 1'b0;
          refresh_needed      <= 1'b0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Main Controller FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    CTRL_INIT      = 4'd0,   // power-on initialization sequence
    CTRL_IDLE      = 4'd1,   // waiting for requests
    CTRL_REFRESH   = 4'd2,   // auto-refresh cycle
    CTRL_PRECHARGE = 4'd3,   // precharge bank before new row activate
    CTRL_ACTIVATE  = 4'd4,   // send ACTIVATE command (RAS)
    CTRL_TRCD_WAIT = 4'd5,   // wait tRCD cycles after activate
    CTRL_READ      = 4'd6,   // send READ command (CAS)
    CTRL_WRITE     = 4'd7,   // send WRITE command (CAS)
    CTRL_TCL_WAIT  = 4'd8,   // wait tCL cycles for read data
    CTRL_DATA_RET  = 4'd9,   // capture read data and return response
    CTRL_TWR_WAIT  = 4'd10   // write recovery time
  } ctrl_state_t;

  ctrl_state_t ctrl_state;
  logic [4:0]  wait_timer;   // general timing countdown
  dram_req_t   active_req;   // request currently being serviced
  logic        active_valid;

  // DRAM command encoding (RAS#, CAS#, WE#)
  localparam logic [2:0] CMD_NOP        = 3'b111;
  localparam logic [2:0] CMD_ACTIVE     = 3'b011;  // RAS
  localparam logic [2:0] CMD_READ       = 3'b101;  // CAS read
  localparam logic [2:0] CMD_WRITE      = 3'b100;  // CAS write
  localparam logic [2:0] CMD_PRECHARGE  = 3'b010;
  localparam logic [2:0] CMD_REFRESH    = 3'b001;
  localparam logic [2:0] CMD_MRS        = 3'b000;  // mode register set

  logic [2:0] dram_cmd;
  assign {dram_ras_n, dram_cas_n, dram_we_n} = dram_cmd;

  // Performance counters
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      perf_reads     <= '0;
      perf_writes    <= '0;
      perf_refreshes <= '0;
      perf_row_hits  <= '0;
      perf_row_misses<= '0;
    end else begin
      if (ctrl_state == CTRL_READ)   perf_reads     <= perf_reads  + 1;
      if (ctrl_state == CTRL_WRITE)  perf_writes    <= perf_writes + 1;
      if (ctrl_state == CTRL_REFRESH) perf_refreshes <= perf_refreshes + 1;
    end
  end

  // Init counter
  logic [7:0] init_counter;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_state    <= CTRL_INIT;
      init_counter  <= 8'd0;
      wait_timer    <= 5'd0;
      active_valid  <= 1'b0;
      resp_valid    <= 1'b0;
      dram_cmd      <= CMD_NOP;
      dram_cke      <= 1'b0;
      dram_cs_n     <= 1'b1;
      dram_ba       <= '0;
      dram_addr     <= '0;
      dram_dq_out   <= '0;
      dram_dm       <= '0;
      q_head        <= '0;
      q_tail        <= '0;
      q_count       <= '0;
      for (int b = 0; b < NUM_BANKS; b++) begin
        open_row[b]   <= '0;
        row_open[b]   <= 1'b0;
        bank_timer[b] <= '0;
      end
    end else begin
      // resp_valid holds until next transaction clears it (TB checks 30 cycles later)
      dram_cmd    <= CMD_NOP;
      dram_cs_n   <= 1'b0;
      dram_cke    <= 1'b1;

      // Decrement bank timers
      for (int b = 0; b < NUM_BANKS; b++) begin
        if (bank_timer[b] > 0) bank_timer[b] <= bank_timer[b] - 5'd1;
      end

      // Enqueue incoming request (negedge-captured, runs every cycle)
      if (req_valid_r && !q_full) begin
        queue[q_tail].wr      <= req_wr_r;
        queue[q_tail].addr    <= req_addr_r;
        queue[q_tail].wdata   <= req_wdata_r;
        queue[q_tail].byte_en <= req_byte_en_r;
        queue[q_tail].tag     <= req_tag_r;
        q_tail  <= q_tail + 3'd1;
        q_count <= q_count + 4'd1;
      end

      case (ctrl_state)
        // ------------------------------------------------------------------
        // INIT: 200 μs power-on wait (100 cycles @ 500 MHz for simulation)
        // ------------------------------------------------------------------
        CTRL_INIT: begin
          dram_cke <= 1'b1;
          if (init_counter < 8'd100) begin
            init_counter <= init_counter + 8'd1;
          end else begin
            // Send MODE REGISTER SET
            dram_cmd  <= CMD_MRS;
            dram_addr <= {4'b0000, 3'b010, 1'b0, 3'b100, 3'b000}; // CL=4
            ctrl_state <= CTRL_IDLE;
          end
        end

        // ------------------------------------------------------------------
        // IDLE: pick next request or refresh
        // ------------------------------------------------------------------
        CTRL_IDLE: begin
          if (refresh_needed && !refresh_in_progress) begin
            // Precharge all banks before refresh
            dram_cmd      <= CMD_PRECHARGE;
            dram_addr[10] <= 1'b1;    // A10=1 → precharge all banks
            for (int b = 0; b < NUM_BANKS; b++)
              row_open[b] <= 1'b0;
            ctrl_state    <= CTRL_REFRESH;
            wait_timer    <= tRP;
          end else if (!q_empty) begin
            // Dequeue next request — clear previous response
            resp_valid   <= 1'b0;
            active_req   <= queue[q_head];
            active_valid <= 1'b1;
            q_head       <= q_head + 3'd1;
            q_count      <= q_count - 4'd1;
            ctrl_state   <= CTRL_PRECHARGE;
          end
        end

        // ------------------------------------------------------------------
        // REFRESH
        // ------------------------------------------------------------------
        CTRL_REFRESH: begin
          if (wait_timer == 0) begin
            dram_cmd            <= CMD_REFRESH;
            refresh_in_progress <= 1'b1;
            refresh_timer       <= tRFC;
            ctrl_state          <= CTRL_IDLE;
            wait_timer          <= tRFC;
          end else
            wait_timer <= wait_timer - 5'd1;
        end

        // ------------------------------------------------------------------
        // PRECHARGE: close open row in target bank if different row needed
        // ------------------------------------------------------------------
        CTRL_PRECHARGE: begin
          begin
            automatic logic [1:0] bank = addr_bank(active_req.addr);
            automatic logic [ROW_BITS-1:0] row = addr_row(active_req.addr);

            if (row_open[bank] && open_row[bank] != row) begin
              // Need to close current row first
              dram_cmd      <= CMD_PRECHARGE;
              dram_ba       <= bank;
              dram_addr[10] <= 1'b0;    // A10=0 → precharge single bank
              row_open[bank]<= 1'b0;
              wait_timer    <= tRP - 1;
              ctrl_state    <= CTRL_ACTIVATE;
            end else begin
              // Row already open (hit) or bank idle (no precharge needed)
              ctrl_state <= CTRL_ACTIVATE;
              wait_timer <= 5'd0;
            end
          end
        end

        // ------------------------------------------------------------------
        // ACTIVATE: send RAS command to open a row
        // ------------------------------------------------------------------
        CTRL_ACTIVATE: begin
          if (wait_timer == 0) begin
            begin
              automatic logic [1:0] bank = addr_bank(active_req.addr);
              automatic logic [ROW_BITS-1:0] row = addr_row(active_req.addr);

              if (!row_open[bank]) begin
                // Send ACTIVATE
                dram_cmd       <= CMD_ACTIVE;
                dram_ba        <= bank;
                dram_addr      <= row;
                open_row[bank] <= row;
                row_open[bank] <= 1'b1;
                bank_timer[bank]<= tRAS;
                wait_timer     <= tRCD - 1;
                ctrl_state     <= CTRL_TRCD_WAIT;
                perf_row_misses<= perf_row_misses + 1;
              end else begin
                // Row hit — skip activate
                wait_timer  <= 5'd0;
                ctrl_state  <= active_req.wr ? CTRL_WRITE : CTRL_READ;
                perf_row_hits <= perf_row_hits + 1;
              end
            end
          end else
            wait_timer <= wait_timer - 5'd1;
        end

        // ------------------------------------------------------------------
        // tRCD wait after ACTIVATE
        // ------------------------------------------------------------------
        CTRL_TRCD_WAIT: begin
          if (wait_timer == 0)
            ctrl_state <= active_req.wr ? CTRL_WRITE : CTRL_READ;
          else
            wait_timer <= wait_timer - 5'd1;
        end

        // ------------------------------------------------------------------
        // READ: send CAS-READ command
        // ------------------------------------------------------------------
        CTRL_READ: begin
          dram_cmd   <= CMD_READ;
          dram_ba    <= addr_bank(active_req.addr);
          dram_addr  <= {4'b0, addr_col(active_req.addr)};
          dram_dm    <= '0;           // no masking on reads
          wait_timer <= tCL - 1;
          ctrl_state <= CTRL_TCL_WAIT;
        end

        // ------------------------------------------------------------------
        // WRITE: send CAS-WRITE command with data
        // ------------------------------------------------------------------
        CTRL_WRITE: begin
          dram_cmd    <= CMD_WRITE;
          dram_ba     <= addr_bank(active_req.addr);
          dram_addr   <= {4'b0, addr_col(active_req.addr)};
          dram_dq_out <= active_req.wdata;
          dram_dm     <= ~active_req.byte_en;  // DM active-low
          wait_timer  <= tWR - 1;
          ctrl_state  <= CTRL_TWR_WAIT;
        end

        // ------------------------------------------------------------------
        // Wait tCL cycles for read data to appear on DQ bus
        // ------------------------------------------------------------------
        CTRL_TCL_WAIT: begin
          if (wait_timer == 0)
            ctrl_state <= CTRL_DATA_RET;
          else
            wait_timer <= wait_timer - 5'd1;
        end

        // ------------------------------------------------------------------
        // Capture read data and return to requester
        // ------------------------------------------------------------------
        CTRL_DATA_RET: begin
          resp_valid  <= 1'b1;
          resp_rdata  <= dram_dq_in;
          resp_tag    <= active_req.tag;
          active_valid<= 1'b0;
          ctrl_state  <= CTRL_IDLE;
        end

        // ------------------------------------------------------------------
        // Write recovery time
        // ------------------------------------------------------------------
        CTRL_TWR_WAIT: begin
          if (wait_timer == 0) begin
            resp_valid   <= 1'b1;    // ack write completion
            resp_rdata   <= '0;
            resp_tag     <= active_req.tag;
            active_valid <= 1'b0;
            ctrl_state   <= CTRL_IDLE;
          end else
            wait_timer <= wait_timer - 5'd1;
        end

      endcase
    end
  end

endmodule


// =============================================================================
// VRAM Physical Model (Simulation Only)
// Simulates the actual DRAM array — responds to DRAM commands
// =============================================================================
// synthesis translate_off
module vram_dram_model #(
  parameter int ROW_BITS  = 14,
  parameter int COL_BITS  = 10,
  parameter int NUM_BANKS = 4,
  parameter int DATA_BITS = 128,
  parameter int tCL       = 4
) (
  input  logic              clk,
  input  logic              cke,
  input  logic              cs_n,
  input  logic              ras_n,
  input  logic              cas_n,
  input  logic              we_n,
  input  logic [1:0]        ba,
  input  logic [ROW_BITS-1:0] addr,
  input  logic [DATA_BITS-1:0] dq_in,
  input  logic [DATA_BITS/8-1:0] dm,
  output logic [DATA_BITS-1:0] dq_out
);

  // DRAM array: simulation-sized (use modulo addressing to avoid 1 GB allocation)
  localparam int SIM_ROWS = 128;
  localparam int SIM_COLS = 64;
  logic [DATA_BITS-1:0] dram_array [0:NUM_BANKS-1][0:SIM_ROWS-1][0:SIM_COLS-1];

  logic [ROW_BITS-1:0] open_row [0:NUM_BANKS-1];
  logic                row_active [0:NUM_BANKS-1];

  logic [DATA_BITS-1:0] read_pipeline [0:tCL];
  logic [COL_BITS-1:0]  col_save;
  logic [1:0]           ba_save;
  int                   read_latency_cnt;

  logic [2:0] cmd;
  assign cmd = {ras_n, cas_n, we_n};

  localparam logic [2:0] CMD_ACTIVE    = 3'b011;
  localparam logic [2:0] CMD_READ      = 3'b101;
  localparam logic [2:0] CMD_WRITE     = 3'b100;
  localparam logic [2:0] CMD_PRECHARGE = 3'b010;

  always_ff @(posedge clk) begin
    dq_out <= '0;
    if (cke && !cs_n) begin
      case (cmd)
        CMD_ACTIVE: begin
          open_row[ba]   <= addr;
          row_active[ba] <= 1'b1;
        end
        CMD_READ: begin
          col_save          <= COL_BITS'(addr[COL_BITS-1:0] % SIM_COLS);
          ba_save           <= ba;
          read_latency_cnt  <= tCL;
        end
        CMD_WRITE: begin
          // Write with byte mask
          for (int b = 0; b < DATA_BITS/8; b++) begin
            if (!dm[b])
              dram_array[ba][open_row[ba] % SIM_ROWS][addr[COL_BITS-1:0] % SIM_COLS][b*8 +: 8] <=
                dq_in[b*8 +: 8];
          end
        end
        CMD_PRECHARGE: begin
          if (addr[10]) begin // all banks
            for (int b = 0; b < NUM_BANKS; b++)
              row_active[b] <= 1'b0;
          end else
            row_active[ba] <= 1'b0;
        end
        default: begin
          // NOP or other commands
        end
      endcase

      // Read pipeline
      if (read_latency_cnt > 0) begin
        read_latency_cnt <= read_latency_cnt - 1;
        if (read_latency_cnt == 1)
          dq_out <= dram_array[ba_save][open_row[ba_save] % SIM_ROWS][col_save];
      end
    end
  end

endmodule
// synthesis translate_on