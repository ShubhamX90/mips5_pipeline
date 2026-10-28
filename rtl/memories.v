`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// Behavioural instruction / data memories (Harvard architecture).
//
// Both have an *asynchronous (combinational) read* and, for the data memory, a
// synchronous byte-enabled write -- the classic textbook memory model that
// lets IF and MEM each complete in one cycle.
//
// Initialisation (simulation only):
//   +IMEM=<file>   $readmemh word-per-line image loaded at address 0
//   +DMEM=<file>   likewise for data memory
// =============================================================================

module imem #(
    parameter WORDS = 4096                       // must be a power of two
) (
    input  wire [31:0] addr,
    output wire [31:0] data
);
    localparam AW = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];

    integer i;
    reg [4095:0] fname;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = `ILLEGAL_FETCH;
        if ($value$plusargs("IMEM=%s", fname)) $readmemh(fname, mem);
    end

    // Fetches outside the mapped range return an illegal instruction, so
    // running off the end of a program halts with ILLEGAL rather than
    // sliding silently through zeros.
    wire in_range = ~|(addr >> (AW + 2));
    assign data = in_range ? mem[addr[AW+1:2]] : `ILLEGAL_FETCH;
endmodule

module dmem #(
    parameter WORDS = 4096
) (
    input  wire        clk,
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);
    localparam AW = $clog2(WORDS);
    reg [31:0] mem [0:WORDS-1];

    integer i;
    reg [4095:0] fname;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'b0;
        if ($value$plusargs("DMEM=%s", fname)) $readmemh(fname, mem);
    end

    wire in_range = ~|(addr >> (AW + 2));
    wire [AW-1:0] widx = addr[AW+1:2];

    assign rdata = in_range ? mem[widx] : 32'b0;

    always @(posedge clk) begin
        if (we && in_range) begin
            if (be[0]) mem[widx][7:0]   <= wdata[7:0];
            if (be[1]) mem[widx][15:8]  <= wdata[15:8];
            if (be[2]) mem[widx][23:16] <= wdata[23:16];
            if (be[3]) mem[widx][31:24] <= wdata[31:24];
        end
    end
endmodule
`default_nettype wire
