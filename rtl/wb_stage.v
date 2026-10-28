`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// wb_stage -- Write-back / retirement / halt control.
//
// The instruction in MEM/WB is the architecturally oldest in flight, so this
// is the precise point at which state is committed and exceptions are taken:
//
//   exc == NONE    : retire; write the register file
//   exc == BREAK   : retire (appears in the trace), then halt
//   exc == ILLEGAL : halt without retiring
//   exc == ADDR    : halt without retiring
//
// `halt_now` clears every younger pipeline stage on the same edge (via `stop`)
// so nothing younger than the halting instruction commits.
// =============================================================================
module wb_stage (
    input  wire        clk,
    input  wire        rst,

    input  wire        memwb_valid,
    input  wire [31:0] memwb_pc,
    input  wire [31:0] memwb_instr,
    input  wire [31:0] memwb_value,
    input  wire [4:0]  memwb_dest,
    input  wire        memwb_reg_write,
    input  wire [1:0]  memwb_exc,
    input  wire [31:0] memwb_bad_addr,
    input  wire [1:0]  memwb_mop,
    input  wire [1:0]  memwb_msize,
    input  wire [31:0] memwb_maddr,
    input  wire [31:0] memwb_mdata,

    // register file write port
    output wire        rf_we,
    output wire [4:0]  rf_waddr,
    output wire [31:0] rf_wdata,

    // halt control
    output wire        halt_now,
    output wire        stop,              // halted | halt_now
    output reg         halted,
    output reg  [1:0]  halt_cause,
    output reg  [31:0] halt_pc,
    output reg  [31:0] halt_addr,

    // retirement interface
    output wire        ret_valid,
    output wire [31:0] ret_pc,
    output wire [31:0] ret_instr,
    output wire        ret_wen,
    output wire [4:0]  ret_waddr,
    output wire [31:0] ret_wdata,
    output wire [1:0]  ret_mem_op,
    output wire [1:0]  ret_mem_size,
    output wire [31:0] ret_mem_addr,
    output wire [31:0] ret_mem_data
);
    wire live   = memwb_valid & ~halted;
    wire commit = live & ((memwb_exc == `EXC_NONE) | (memwb_exc == `EXC_BREAK));

    assign halt_now = live & (memwb_exc != `EXC_NONE);
    assign stop     = halted | halt_now;

    assign rf_we    = commit & memwb_reg_write & (memwb_dest != 5'd0);
    assign rf_waddr = memwb_dest;
    assign rf_wdata = memwb_value;

    assign ret_valid    = commit;
    assign ret_pc       = memwb_pc;
    assign ret_instr    = memwb_instr;
    assign ret_wen      = rf_we;
    assign ret_waddr    = rf_we ? memwb_dest  : 5'd0;
    assign ret_wdata    = rf_we ? memwb_value : 32'b0;
    assign ret_mem_op   = memwb_mop;
    assign ret_mem_size = memwb_msize;
    assign ret_mem_addr = memwb_maddr;
    assign ret_mem_data = memwb_mdata;

    always @(posedge clk) begin
        if (rst) begin
            halted     <= 1'b0;
            halt_cause <= `EXC_NONE;
            halt_pc    <= 32'b0;
            halt_addr  <= 32'b0;
        end else if (halt_now) begin
            halted     <= 1'b1;
            halt_cause <= memwb_exc;
            halt_pc    <= memwb_pc;
            halt_addr  <= memwb_bad_addr;
        end
    end
endmodule
`default_nettype wire
