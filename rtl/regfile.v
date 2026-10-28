`default_nettype none
// =============================================================================
// regfile -- 32 x 32-bit register file, 2 read ports, 1 write port.
//
// * $0 is hard-wired to zero (reads return 0, writes are ignored).
// * Write is synchronous (rising edge).  Reads are combinational and include a
//   write-through bypass: a read of the register being written in the same
//   cycle returns the incoming write data.  This is what resolves the
//   distance-3 RAW hazard (producer in WB while consumer is in ID) without any
//   extra forwarding path or stall.  The single-cycle core builds it with
//   BYPASS=0: there the write data depends combinationally on the read data,
//   so a bypass would create a (false but real) combinational loop.
// * Registers are zero-initialised (FPGA-style init) for simulation; the ISS
//   assumes the same architectural reset state.
// =============================================================================
module regfile #(
    parameter BYPASS = 1        // 1: write-through read bypass (pipeline); 0: plain array (single-cycle)
) (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    output wire [31:0] rdata1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata2
);
    reg [31:0] regs [0:31];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'b0;

    always @(posedge clk)
        if (we && waddr != 5'd0) regs[waddr] <= wdata;

    assign rdata1 = (raddr1 == 5'd0)            ? 32'b0 :
                    (BYPASS != 0 && we && waddr == raddr1) ? wdata :
                                                  regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0)            ? 32'b0 :
                    (BYPASS != 0 && we && waddr == raddr2) ? wdata :
                                                  regs[raddr2];
endmodule
`default_nettype wire
