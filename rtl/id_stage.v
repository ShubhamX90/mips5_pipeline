`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// id_stage -- Instruction Decode / register read.  Owns the ID/EX register.
//
// Combinational outputs (for hazard control and the register file):
//   id_*  : decoded view of the instruction currently in IF/ID
//   rf_*  : register-file read addresses
// Registered outputs (idex_*): the instruction presented to EX.
//
// ID/EX is loaded with a bubble (valid=0, every control zero) on reset, flush,
// stall (load-use) or when IF/ID itself holds a bubble.  A bubble therefore
// cannot write a register, access memory, redirect the PC, or raise an
// exception, regardless of any `valid` gating downstream.
// =============================================================================
module id_stage (
    input  wire        clk,
    input  wire        rst,
    input  wire        stop,
    input  wire        stall,           // load-use stall: insert bubble into EX
    input  wire        flush,           // wrong path: kill the instruction in ID

    // from IF/ID
    input  wire        ifid_valid,
    input  wire [31:0] ifid_pc,
    input  wire [31:0] ifid_instr,

    // register file read port
    output wire [4:0]  rf_raddr1,
    output wire [4:0]  rf_raddr2,
    input  wire [31:0] rf_rdata1,
    input  wire [31:0] rf_rdata2,

    // combinational decode info for the hazard unit
    output wire [4:0]  id_rs,
    output wire [4:0]  id_rt,
    output wire        id_uses_rs,
    output wire        id_uses_rt,
    output wire        id_is_store,
    output wire        id_jump,         // valid j/jal in ID
    output wire [31:0] id_jump_target,

    // ID/EX pipeline register
    output reg         idex_valid,
    output reg  [31:0] idex_pc,
    output reg  [31:0] idex_pc4,
    output reg  [31:0] idex_instr,
    output reg  [4:0]  idex_rs,
    output reg  [4:0]  idex_rt,
    output reg         idex_uses_rs,
    output reg         idex_uses_rt,
    output reg  [31:0] idex_rs_val,
    output reg  [31:0] idex_rt_val,
    output reg  [31:0] idex_imm,
    output reg  [4:0]  idex_shamt,
    output reg  [4:0]  idex_dest,
    output reg         idex_reg_write,
    output reg  [3:0]  idex_alu_op,
    output reg         idex_alu_src_imm,
    output reg         idex_shamt_sel,
    output reg  [2:0]  idex_br_type,
    output reg         idex_is_jr,
    output reg         idex_is_link,
    output reg  [31:0] idex_br_target,
    output reg         idex_mem_read,
    output reg         idex_mem_write,
    output reg  [1:0]  idex_mem_size,
    output reg         idex_mem_signed,
    output reg  [1:0]  idex_exc
);
    // ---- decode -------------------------------------------------------------
    wire [4:0] d_rs, d_rt, d_rd, d_shamt, d_dest;
    wire       d_reg_write, d_uses_rs, d_uses_rt;
    wire [3:0] d_alu_op;
    wire       d_alu_src_imm, d_shamt_sel, d_imm_zext;
    wire [2:0] d_br_type;
    wire       d_is_jr, d_is_link, d_is_jump;
    wire       d_mem_read, d_mem_write, d_mem_signed;
    wire [1:0] d_mem_size, d_exc;

    decoder u_dec (
        .instr(ifid_instr),
        .rs(d_rs), .rt(d_rt), .rd(d_rd), .shamt(d_shamt),
        .dest(d_dest), .reg_write(d_reg_write),
        .uses_rs(d_uses_rs), .uses_rt(d_uses_rt),
        .alu_op(d_alu_op), .alu_src_imm(d_alu_src_imm),
        .shamt_sel(d_shamt_sel), .imm_zext(d_imm_zext),
        .br_type(d_br_type), .is_jr(d_is_jr), .is_link(d_is_link),
        .is_jump(d_is_jump),
        .mem_read(d_mem_read), .mem_write(d_mem_write),
        .mem_size(d_mem_size), .mem_signed(d_mem_signed),
        .exc(d_exc)
    );

    assign rf_raddr1 = d_rs;
    assign rf_raddr2 = d_rt;

    wire [31:0] pc4  = ifid_pc + 32'd4;
    wire [31:0] imm  = d_imm_zext ? {16'b0, ifid_instr[15:0]}
                                  : {{16{ifid_instr[15]}}, ifid_instr[15:0]};
    wire [31:0] br_target = pc4 + {imm[29:0], 2'b00};     // imm is sign-extended for branches

    assign id_rs          = d_rs;
    assign id_rt          = d_rt;
    assign id_uses_rs     = ifid_valid & d_uses_rs;
    assign id_uses_rt     = ifid_valid & d_uses_rt;
    assign id_is_store    = d_mem_write;
    assign id_jump        = ifid_valid & d_is_jump;
    assign id_jump_target = {pc4[31:28], ifid_instr[25:0], 2'b00};

    // ---- ID/EX register -------------------------------------------------------
    wire bubble = rst | stop | flush | stall | ~ifid_valid;

    always @(posedge clk) begin
        if (bubble) begin
            idex_valid       <= 1'b0;
            idex_pc          <= 32'b0;
            idex_pc4         <= 32'b0;
            idex_instr       <= `NOP_INSTR;
            idex_rs          <= 5'd0;
            idex_rt          <= 5'd0;
            idex_uses_rs     <= 1'b0;
            idex_uses_rt     <= 1'b0;
            idex_rs_val      <= 32'b0;
            idex_rt_val      <= 32'b0;
            idex_imm         <= 32'b0;
            idex_shamt       <= 5'd0;
            idex_dest        <= 5'd0;
            idex_reg_write   <= 1'b0;
            idex_alu_op      <= `ALU_ADD;
            idex_alu_src_imm <= 1'b0;
            idex_shamt_sel   <= 1'b0;
            idex_br_type     <= `BR_NONE;
            idex_is_jr       <= 1'b0;
            idex_is_link     <= 1'b0;
            idex_br_target   <= 32'b0;
            idex_mem_read    <= 1'b0;
            idex_mem_write   <= 1'b0;
            idex_mem_size    <= `SZ_W;
            idex_mem_signed  <= 1'b0;
            idex_exc         <= `EXC_NONE;
        end else begin
            idex_valid       <= 1'b1;
            idex_pc          <= ifid_pc;
            idex_pc4         <= pc4;
            idex_instr       <= ifid_instr;
            idex_rs          <= d_rs;
            idex_rt          <= d_rt;
            idex_uses_rs     <= d_uses_rs;
            idex_uses_rt     <= d_uses_rt;
            idex_rs_val      <= rf_rdata1;
            idex_rt_val      <= rf_rdata2;
            idex_imm         <= imm;
            idex_shamt       <= d_shamt;
            idex_dest        <= d_dest;
            idex_reg_write   <= d_reg_write;
            idex_alu_op      <= d_alu_op;
            idex_alu_src_imm <= d_alu_src_imm;
            idex_shamt_sel   <= d_shamt_sel;
            idex_br_type     <= d_br_type;
            idex_is_jr       <= d_is_jr;
            idex_is_link     <= d_is_link;
            idex_br_target   <= br_target;
            idex_mem_read    <= d_mem_read;
            idex_mem_write   <= d_mem_write;
            idex_mem_size    <= d_mem_size;
            idex_mem_signed  <= d_mem_signed;
            idex_exc         <= d_exc;
        end
    end
endmodule
`default_nettype wire
