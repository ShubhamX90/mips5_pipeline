`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// if_stage -- Instruction Fetch.  Owns the PC and the IF/ID pipeline register.
//
// Next-PC priority (highest first):
//   1. redirect_ex  -- taken branch / jr / jalr resolved in EX
//   2. redirect_id  -- j / jal resolved in ID
//   3. hold         -- load-use stall (PC frozen)
//   4. PC + 4
//
// IF/ID register control:
//   flush : the instruction fetched this cycle is wrong-path -> store a bubble
//   stall : hold the register (the instruction in ID is being held back)
//   stop  : core is halting; stop fetching and clear the valid bit
// =============================================================================
module if_stage #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        stop,
    input  wire        stall,
    input  wire        flush,
    input  wire        redirect_ex,
    input  wire [31:0] target_ex,
    input  wire        redirect_id,
    input  wire [31:0] target_id,

    // instruction memory port
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    // IF/ID pipeline register
    output reg         ifid_valid,
    output reg  [31:0] ifid_pc,
    output reg  [31:0] ifid_instr
);
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;

    assign imem_addr = pc;

    wire [31:0] next_pc = redirect_ex ? target_ex :
                          redirect_id ? target_id :
                                        pc_plus4;
    wire pc_en = redirect_ex | redirect_id | ~stall;

    always @(posedge clk) begin
        if (rst) begin
            pc         <= RESET_PC;
            ifid_valid <= 1'b0;
            ifid_pc    <= 32'b0;
            ifid_instr <= `NOP_INSTR;
        end else if (stop) begin
            ifid_valid <= 1'b0;
        end else begin
            if (pc_en) pc <= next_pc;
            if (flush) begin
                ifid_valid <= 1'b0;
                ifid_instr <= `NOP_INSTR;
            end else if (!stall) begin
                ifid_valid <= 1'b1;
                ifid_pc    <= pc;
                ifid_instr <= imem_data;
            end
        end
    end
endmodule
`default_nettype wire
