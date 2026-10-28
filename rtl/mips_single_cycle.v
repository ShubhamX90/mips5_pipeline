`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// mips_single_cycle -- non-pipelined baseline: one instruction per clock.
//
// Built from the *same* decoder / ALU / branch_cond / regfile / memory-helper
// modules as the pipelined core, and exposes the identical port list
// (retirement trace, halt status, event pulses) so the same testbench,
// reference model and regression flow validate both.  It exists to benchmark
// the pipeline against: CPI is exactly 1, but the combinational path
// (IMEM -> RF -> ALU -> DMEM -> RF) is the sum of all five stage delays.
// =============================================================================
module mips_single_cycle #(
    parameter [31:0] RESET_PC       = 32'h0000_0000,
    parameter        MEM_MEM_FWD    = 1,          // unused; keeps parameter list identical
    parameter        DMEM_ADDR_BITS = 14
) (
    input  wire        clk,
    input  wire        rst,

    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_be,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,

    output reg         halted,
    output reg  [1:0]  halt_cause,
    output reg  [31:0] halt_pc,
    output reg  [31:0] halt_addr,

    output wire        ret_valid,
    output wire [31:0] ret_pc,
    output wire [31:0] ret_instr,
    output wire        ret_wen,
    output wire [4:0]  ret_waddr,
    output wire [31:0] ret_wdata,
    output wire [1:0]  ret_mem_op,
    output wire [1:0]  ret_mem_size,
    output wire [31:0] ret_mem_addr,
    output wire [31:0] ret_mem_data,

    output wire        evt_stall,
    output wire        evt_ex_redirect,
    output wire        evt_id_redirect,
    output wire [1:0]  evt_squash,
    output wire        evt_br,
    output wire        evt_br_taken,
    output wire [1:0]  evt_fwd_exmem,
    output wire [1:0]  evt_fwd_memwb
);
    reg [31:0] pc;
    assign imem_addr = pc;
    wire [31:0] instr = imem_data;

    // ---- decode ---------------------------------------------------------------
    wire [4:0] rs, rt, rd, shamt, dest;
    wire       reg_write, uses_rs, uses_rt, alu_src_imm, shamt_sel, imm_zext;
    wire [3:0] alu_op;  wire [2:0] br_type;
    wire       is_jr, is_link, is_jump, mem_read, mem_write, mem_signed;
    wire [1:0] mem_size, dec_exc;

    decoder u_dec (
        .instr(instr), .rs(rs), .rt(rt), .rd(rd), .shamt(shamt),
        .dest(dest), .reg_write(reg_write), .uses_rs(uses_rs), .uses_rt(uses_rt),
        .alu_op(alu_op), .alu_src_imm(alu_src_imm), .shamt_sel(shamt_sel),
        .imm_zext(imm_zext), .br_type(br_type), .is_jr(is_jr), .is_link(is_link),
        .is_jump(is_jump), .mem_read(mem_read), .mem_write(mem_write),
        .mem_size(mem_size), .mem_signed(mem_signed), .exc(dec_exc)
    );

    // ---- register file ---------------------------------------------------------
    wire [31:0] rs_val, rt_val;
    wire        rf_we;
    wire [31:0] rf_wdata;
    regfile #(.BYPASS(0)) u_rf (
        .clk(clk), .we(rf_we), .waddr(dest), .wdata(rf_wdata),
        .raddr1(rs), .rdata1(rs_val), .raddr2(rt), .rdata2(rt_val)
    );

    // ---- execute -----------------------------------------------------------------
    wire [31:0] pc4 = pc + 32'd4;
    wire [31:0] imm = imm_zext ? {16'b0, instr[15:0]} : {{16{instr[15]}}, instr[15:0]};
    wire [31:0] alu_a = shamt_sel   ? {27'b0, shamt} : rs_val;
    wire [31:0] alu_b = alu_src_imm ? imm            : rt_val;
    wire [31:0] alu_y;
    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

    wire br_taken;
    branch_cond u_bc (.br_type(br_type), .a(rs_val), .b(rt_val), .taken(br_taken));
    wire jr_misaligned = is_jr & (rs_val[1:0] != 2'b00);

    // ---- memory ------------------------------------------------------------------
    wire addr_fault_c;
    mem_check #(.ADDR_BITS(DMEM_ADDR_BITS)) u_chk (
        .addr(alu_y), .size(mem_size), .fault(addr_fault_c));
    wire mem_fault = (mem_read | mem_write) & addr_fault_c;

    store_fmt u_sf (.data(rt_val), .byte_off(alu_y[1:0]), .size(mem_size),
                    .wdata(dmem_wdata), .be(dmem_be));
    wire [31:0] load_val;
    load_fmt u_lf (.word(dmem_rdata), .byte_off(alu_y[1:0]), .size(mem_size),
                   .sign_ext(mem_signed), .value(load_val));

    wire [1:0] exc = (dec_exc != `EXC_NONE)       ? dec_exc  :
                     (mem_fault | jr_misaligned)  ? `EXC_ADDR : `EXC_NONE;
    wire live   = ~halted & ~rst;
    wire commit = live & ((exc == `EXC_NONE) | (exc == `EXC_BREAK));

    assign dmem_addr = alu_y;
    assign dmem_we   = live & mem_write & (exc == `EXC_NONE);

    assign rf_wdata = is_link ? pc4 : mem_read ? load_val : alu_y;
    assign rf_we    = commit & reg_write & (dest != 5'd0) & ~mem_fault & ~jr_misaligned;

    wire [31:0] branch_target = pc4 + {imm[29:0], 2'b00};
    wire [31:0] next_pc = (br_type != `BR_NONE && br_taken) ? branch_target :
                          is_jr                              ? rs_val :
                          is_jump                            ? {pc4[31:28], instr[25:0], 2'b00} :
                                                               pc4;

    always @(posedge clk) begin
        if (rst) begin
            pc         <= RESET_PC;
            halted     <= 1'b0;
            halt_cause <= `EXC_NONE;
            halt_pc    <= 32'b0;
            halt_addr  <= 32'b0;
        end else if (live) begin
            if (exc != `EXC_NONE) begin
                halted     <= 1'b1;
                halt_cause <= exc;
                halt_pc    <= pc;
                halt_addr  <= jr_misaligned ? rs_val : alu_y;
            end else begin
                pc <= next_pc;
            end
        end
    end

    // ---- retirement ------------------------------------------------------------------
    wire [31:0] st_masked = (mem_size == `SZ_B) ? {24'b0, rt_val[7:0]}  :
                            (mem_size == `SZ_H) ? {16'b0, rt_val[15:0]} : rt_val;

    assign ret_valid    = commit;
    assign ret_pc       = pc;
    assign ret_instr    = instr;
    assign ret_wen      = rf_we;
    assign ret_waddr    = rf_we ? dest     : 5'd0;
    assign ret_wdata    = rf_we ? rf_wdata : 32'b0;
    assign ret_mem_op   = mem_read ? `MOP_LOAD : mem_write ? `MOP_STORE : `MOP_NONE;
    assign ret_mem_size = mem_size;
    assign ret_mem_addr = alu_y;
    assign ret_mem_data = mem_read ? load_val : st_masked;

    // ---- events (only branch statistics are meaningful for a single-cycle core)
    assign evt_stall       = 1'b0;
    assign evt_ex_redirect = 1'b0;
    assign evt_id_redirect = 1'b0;
    assign evt_squash      = 2'd0;
    assign evt_br          = commit & (br_type != `BR_NONE);
    assign evt_br_taken    = commit & (br_type != `BR_NONE) & br_taken;
    assign evt_fwd_exmem   = 2'd0;
    assign evt_fwd_memwb   = 2'd0;
endmodule
`default_nettype wire
