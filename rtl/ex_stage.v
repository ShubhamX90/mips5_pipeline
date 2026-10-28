`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// ex_stage -- Execute.  Operand forwarding, ALU, branch/jr resolution.
// Owns the EX/MEM pipeline register.
//
// Branches, jr and jalr are resolved here (penalty: 2 flushed instructions).
// The comparison and jr target use the *forwarded* operands, so no extra
// forwarding network is needed for control flow.
//
// A jr/jalr to a non-word-aligned address raises EXC_ADDR on the jump itself
// and does not redirect (the core halts when it reaches write-back).
// =============================================================================
module ex_stage (
    input  wire        clk,
    input  wire        rst,
    input  wire        stop,

    // ID/EX
    input  wire        idex_valid,
    input  wire [31:0] idex_pc,
    input  wire [31:0] idex_pc4,
    input  wire [31:0] idex_instr,
    input  wire [31:0] idex_rs_val,
    input  wire [31:0] idex_rt_val,
    input  wire [31:0] idex_imm,
    input  wire [4:0]  idex_rt,
    input  wire [4:0]  idex_shamt,
    input  wire [4:0]  idex_dest,
    input  wire        idex_reg_write,
    input  wire [3:0]  idex_alu_op,
    input  wire        idex_alu_src_imm,
    input  wire        idex_shamt_sel,
    input  wire [2:0]  idex_br_type,
    input  wire        idex_is_jr,
    input  wire        idex_is_link,
    input  wire [31:0] idex_br_target,
    input  wire        idex_mem_read,
    input  wire        idex_mem_write,
    input  wire [1:0]  idex_mem_size,
    input  wire        idex_mem_signed,
    input  wire [1:0]  idex_exc,

    // forwarding
    input  wire [1:0]  fwd_a,
    input  wire [1:0]  fwd_b,
    input  wire [31:0] fwd_exmem_val,
    input  wire [31:0] fwd_memwb_val,

    // control-flow resolution
    output wire        ex_redirect,
    output wire [31:0] ex_target,
    output wire        ex_br_cond,        // a conditional branch is executing (valid)
    output wire        ex_br_taken,

    // EX/MEM pipeline register
    output reg         exmem_valid,
    output reg  [31:0] exmem_pc,
    output reg  [31:0] exmem_instr,
    output reg  [31:0] exmem_result,      // ALU result, link address, or bad jr target
    output reg  [31:0] exmem_rt_val,      // (forwarded) store data
    output reg  [4:0]  exmem_rt,
    output reg  [4:0]  exmem_dest,
    output reg         exmem_reg_write,
    output reg         exmem_mem_read,
    output reg         exmem_mem_write,
    output reg  [1:0]  exmem_mem_size,
    output reg         exmem_mem_signed,
    output reg  [1:0]  exmem_exc
);
    // ---- operand forwarding -------------------------------------------------
    wire [31:0] op_a = (fwd_a == 2'd1) ? fwd_exmem_val :
                       (fwd_a == 2'd2) ? fwd_memwb_val : idex_rs_val;
    wire [31:0] op_b = (fwd_b == 2'd1) ? fwd_exmem_val :
                       (fwd_b == 2'd2) ? fwd_memwb_val : idex_rt_val;

    wire [31:0] alu_a = idex_shamt_sel   ? {27'b0, idex_shamt} : op_a;
    wire [31:0] alu_b = idex_alu_src_imm ? idex_imm            : op_b;

    wire [31:0] alu_y;
    alu u_alu (.a(alu_a), .b(alu_b), .op(idex_alu_op), .y(alu_y));

    // ---- control-flow resolution ---------------------------------------------
    wire br_taken_raw;
    branch_cond u_bc (.br_type(idex_br_type), .a(op_a), .b(op_b), .taken(br_taken_raw));

    wire jr_misaligned = idex_valid & idex_is_jr & (op_a[1:0] != 2'b00);

    assign ex_br_cond  = idex_valid & (idex_br_type != `BR_NONE);
    assign ex_br_taken = ex_br_cond & br_taken_raw;
    assign ex_redirect = ex_br_taken | (idex_valid & idex_is_jr & ~jr_misaligned);
    assign ex_target   = idex_is_jr ? op_a : idex_br_target;

    // ---- EX/MEM register -----------------------------------------------------
    wire [31:0] result = jr_misaligned ? op_a :
                         idex_is_link  ? idex_pc4 : alu_y;

    always @(posedge clk) begin
        if (rst || stop || !idex_valid) begin
            exmem_valid      <= 1'b0;
            exmem_pc         <= 32'b0;
            exmem_instr      <= `NOP_INSTR;
            exmem_result     <= 32'b0;
            exmem_rt_val     <= 32'b0;
            exmem_rt         <= 5'd0;
            exmem_dest       <= 5'd0;
            exmem_reg_write  <= 1'b0;
            exmem_mem_read   <= 1'b0;
            exmem_mem_write  <= 1'b0;
            exmem_mem_size   <= `SZ_W;
            exmem_mem_signed <= 1'b0;
            exmem_exc        <= `EXC_NONE;
        end else begin
            exmem_valid      <= 1'b1;
            exmem_pc         <= idex_pc;
            exmem_instr      <= idex_instr;
            exmem_result     <= result;
            exmem_rt_val     <= op_b;
            exmem_rt         <= idex_rt;
            exmem_dest       <= idex_dest;
            exmem_reg_write  <= idex_reg_write & ~jr_misaligned;
            exmem_mem_read   <= idex_mem_read;
            exmem_mem_write  <= idex_mem_write;
            exmem_mem_size   <= idex_mem_size;
            exmem_mem_signed <= idex_mem_signed;
            exmem_exc        <= jr_misaligned ? `EXC_ADDR : idex_exc;
        end
    end
endmodule
`default_nettype wire
