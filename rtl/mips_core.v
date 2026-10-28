`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// mips_core -- 5-stage pipelined 32-bit MIPS core (IF / ID / EX / MEM / WB)
//
//   +------+  IF/ID  +------+  ID/EX  +------+  EX/MEM  +------+  MEM/WB  +------+
//   |  IF  |-------->|  ID  |-------->|  EX  |--------->|  MEM |--------->|  WB  |
//   +------+         +------+         +------+          +------+          +------+
//      ^   PC           | regfile         | ALU, fwd mux     | dmem            | rf write
//      |                |  (WB bypass)    | branch/jr resolve|                 | retire / halt
//      +-- redirect_id (j/jal) / redirect_ex (taken br, jr, jalr)
//
// Hazard handling
//   RAW (ALU->ALU)  : EX/MEM->EX and MEM/WB->EX forwarding; regfile write-through
//   RAW (load-use)  : 1-cycle interlock, then MEM/WB->EX forwarding
//   Control         : branch/jr/jalr resolved in EX (2-slot flush),
//                     j/jal resolved in ID (1-slot flush); predict not-taken
//
// Architectural simplifications (see docs/ISA.md): no branch delay slot,
// link address is PC+4, no overflow traps, Harvard memories with
// combinational read.
//
// Ports ending in the same names as mips_single_cycle so the two cores are
// drop-in interchangeable in the testbench.
// =============================================================================
module mips_core #(
    parameter [31:0] RESET_PC       = 32'h0000_0000,
    parameter        MEM_MEM_FWD    = 1,
    parameter        DMEM_ADDR_BITS = 14
) (
    input  wire        clk,
    input  wire        rst,                 // synchronous, active high

    // instruction memory (combinational read)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    // data memory (combinational read, synchronous byte-enable write)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_be,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,

    // halt status
    output wire        halted,
    output wire [1:0]  halt_cause,
    output wire [31:0] halt_pc,
    output wire [31:0] halt_addr,

    // retirement trace (one instruction per cycle at most, in program order)
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

    // performance events (single-cycle pulses / small counts)
    output wire        evt_stall,           // load-use bubble inserted
    output wire        evt_ex_redirect,     // taken branch / jr / jalr
    output wire        evt_id_redirect,     // j / jal
    output wire [1:0]  evt_squash,          // valid instruction slots flushed this cycle
    output wire        evt_br,              // conditional branch executed
    output wire        evt_br_taken,
    output wire [1:0]  evt_fwd_exmem,       // operands forwarded from EX/MEM
    output wire [1:0]  evt_fwd_memwb        // operands forwarded from MEM/WB
);
    // ---------------------------------------------------------------- wires
    wire stop, halt_now;
    wire stall, load_use, flush_ifid, flush_idex, redirect_id;
    wire ex_redirect;  wire [31:0] ex_target;
    wire ex_br_cond, ex_br_taken;

    // IF/ID
    wire        ifid_valid;  wire [31:0] ifid_pc, ifid_instr;
    // ID combinational
    wire [4:0]  rf_raddr1, rf_raddr2;  wire [31:0] rf_rdata1, rf_rdata2;
    wire [4:0]  id_rs, id_rt;  wire id_uses_rs, id_uses_rt, id_is_store, id_jump;
    wire [31:0] id_jump_target;
    // ID/EX
    wire        idex_valid;  wire [31:0] idex_pc, idex_pc4, idex_instr;
    wire [4:0]  idex_rs, idex_rt, idex_shamt, idex_dest;
    wire        idex_uses_rs, idex_uses_rt;
    wire [31:0] idex_rs_val, idex_rt_val, idex_imm, idex_br_target;
    wire        idex_reg_write, idex_alu_src_imm, idex_shamt_sel, idex_is_jr, idex_is_link;
    wire        idex_mem_read, idex_mem_write, idex_mem_signed;
    wire [3:0]  idex_alu_op;  wire [2:0] idex_br_type;
    wire [1:0]  idex_mem_size, idex_exc;
    // forwarding
    wire [1:0]  fwd_a, fwd_b;
    // EX/MEM
    wire        exmem_valid;  wire [31:0] exmem_pc, exmem_instr, exmem_result, exmem_rt_val;
    wire [4:0]  exmem_rt, exmem_dest;
    wire        exmem_reg_write, exmem_mem_read, exmem_mem_write, exmem_mem_signed;
    wire [1:0]  exmem_mem_size, exmem_exc;
    // MEM
    wire        mem_fault, st_fwd;
    // MEM/WB
    wire        memwb_valid;  wire [31:0] memwb_pc, memwb_instr, memwb_value, memwb_bad_addr;
    wire [31:0] memwb_maddr, memwb_mdata;
    wire [4:0]  memwb_dest;  wire memwb_reg_write;
    wire [1:0]  memwb_exc, memwb_mop, memwb_msize;
    // WB
    wire        rf_we;  wire [4:0] rf_waddr;  wire [31:0] rf_wdata;

    // ------------------------------------------------------------------ IF
    if_stage #(.RESET_PC(RESET_PC)) u_if (
        .clk(clk), .rst(rst), .stop(stop),
        .stall(stall), .flush(flush_ifid),
        .redirect_ex(ex_redirect), .target_ex(ex_target),
        .redirect_id(redirect_id), .target_id(id_jump_target),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .ifid_valid(ifid_valid), .ifid_pc(ifid_pc), .ifid_instr(ifid_instr)
    );

    // ------------------------------------------------------- register file
    regfile u_rf (
        .clk(clk), .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
        .raddr1(rf_raddr1), .rdata1(rf_rdata1),
        .raddr2(rf_raddr2), .rdata2(rf_rdata2)
    );

    // ------------------------------------------------------------------ ID
    id_stage u_id (
        .clk(clk), .rst(rst), .stop(stop), .stall(stall), .flush(flush_idex),
        .ifid_valid(ifid_valid), .ifid_pc(ifid_pc), .ifid_instr(ifid_instr),
        .rf_raddr1(rf_raddr1), .rf_raddr2(rf_raddr2),
        .rf_rdata1(rf_rdata1), .rf_rdata2(rf_rdata2),
        .id_rs(id_rs), .id_rt(id_rt), .id_uses_rs(id_uses_rs), .id_uses_rt(id_uses_rt),
        .id_is_store(id_is_store), .id_jump(id_jump), .id_jump_target(id_jump_target),
        .idex_valid(idex_valid), .idex_pc(idex_pc), .idex_pc4(idex_pc4), .idex_instr(idex_instr),
        .idex_rs(idex_rs), .idex_rt(idex_rt),
        .idex_uses_rs(idex_uses_rs), .idex_uses_rt(idex_uses_rt),
        .idex_rs_val(idex_rs_val), .idex_rt_val(idex_rt_val), .idex_imm(idex_imm),
        .idex_shamt(idex_shamt), .idex_dest(idex_dest), .idex_reg_write(idex_reg_write),
        .idex_alu_op(idex_alu_op), .idex_alu_src_imm(idex_alu_src_imm),
        .idex_shamt_sel(idex_shamt_sel), .idex_br_type(idex_br_type),
        .idex_is_jr(idex_is_jr), .idex_is_link(idex_is_link), .idex_br_target(idex_br_target),
        .idex_mem_read(idex_mem_read), .idex_mem_write(idex_mem_write),
        .idex_mem_size(idex_mem_size), .idex_mem_signed(idex_mem_signed),
        .idex_exc(idex_exc)
    );

    // -------------------------------------------------------------- hazards
    hazard_unit #(.MEM_MEM_FWD(MEM_MEM_FWD)) u_hz (
        .id_rs(id_rs), .id_rt(id_rt), .id_uses_rs(id_uses_rs), .id_uses_rt(id_uses_rt),
        .id_is_store(id_is_store), .id_jump(id_jump),
        .ex_valid(idex_valid), .ex_mem_read(idex_mem_read),
        .ex_reg_write(idex_reg_write), .ex_dest(idex_dest), .ex_redirect(ex_redirect),
        .load_use(load_use), .stall(stall),
        .flush_ifid(flush_ifid), .flush_idex(flush_idex), .redirect_id(redirect_id)
    );

    forwarding_unit u_fwd (
        .ex_rs(idex_rs), .ex_rt(idex_rt),
        .exmem_we(exmem_valid & exmem_reg_write), .exmem_dest(exmem_dest),
        .memwb_we(memwb_valid & memwb_reg_write), .memwb_dest(memwb_dest),
        .fwd_a(fwd_a), .fwd_b(fwd_b)
    );

    // ------------------------------------------------------------------ EX
    ex_stage u_ex (
        .clk(clk), .rst(rst), .stop(stop),
        .idex_valid(idex_valid), .idex_pc(idex_pc), .idex_pc4(idex_pc4), .idex_instr(idex_instr),
        .idex_rs_val(idex_rs_val), .idex_rt_val(idex_rt_val), .idex_imm(idex_imm),
        .idex_rt(idex_rt), .idex_shamt(idex_shamt), .idex_dest(idex_dest),
        .idex_reg_write(idex_reg_write), .idex_alu_op(idex_alu_op),
        .idex_alu_src_imm(idex_alu_src_imm), .idex_shamt_sel(idex_shamt_sel),
        .idex_br_type(idex_br_type), .idex_is_jr(idex_is_jr), .idex_is_link(idex_is_link),
        .idex_br_target(idex_br_target),
        .idex_mem_read(idex_mem_read), .idex_mem_write(idex_mem_write),
        .idex_mem_size(idex_mem_size), .idex_mem_signed(idex_mem_signed), .idex_exc(idex_exc),
        .fwd_a(fwd_a), .fwd_b(fwd_b),
        .fwd_exmem_val(exmem_result), .fwd_memwb_val(memwb_value),
        .ex_redirect(ex_redirect), .ex_target(ex_target),
        .ex_br_cond(ex_br_cond), .ex_br_taken(ex_br_taken),
        .exmem_valid(exmem_valid), .exmem_pc(exmem_pc), .exmem_instr(exmem_instr),
        .exmem_result(exmem_result), .exmem_rt_val(exmem_rt_val), .exmem_rt(exmem_rt),
        .exmem_dest(exmem_dest), .exmem_reg_write(exmem_reg_write),
        .exmem_mem_read(exmem_mem_read), .exmem_mem_write(exmem_mem_write),
        .exmem_mem_size(exmem_mem_size), .exmem_mem_signed(exmem_mem_signed),
        .exmem_exc(exmem_exc)
    );

    // ----------------------------------------------------------------- MEM
    mem_stage #(.MEM_MEM_FWD(MEM_MEM_FWD), .DMEM_ADDR_BITS(DMEM_ADDR_BITS)) u_mem (
        .clk(clk), .rst(rst), .stop(stop),
        .exmem_valid(exmem_valid), .exmem_pc(exmem_pc), .exmem_instr(exmem_instr),
        .exmem_result(exmem_result), .exmem_rt_val(exmem_rt_val), .exmem_rt(exmem_rt),
        .exmem_dest(exmem_dest), .exmem_reg_write(exmem_reg_write),
        .exmem_mem_read(exmem_mem_read), .exmem_mem_write(exmem_mem_write),
        .exmem_mem_size(exmem_mem_size), .exmem_mem_signed(exmem_mem_signed),
        .exmem_exc(exmem_exc),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata),
        .mem_fault(mem_fault), .st_fwd(st_fwd),
        .memwb_valid(memwb_valid), .memwb_pc(memwb_pc), .memwb_instr(memwb_instr),
        .memwb_value(memwb_value), .memwb_dest(memwb_dest),
        .memwb_reg_write(memwb_reg_write), .memwb_exc(memwb_exc),
        .memwb_bad_addr(memwb_bad_addr), .memwb_mop(memwb_mop), .memwb_msize(memwb_msize),
        .memwb_maddr(memwb_maddr), .memwb_mdata(memwb_mdata)
    );

    // ------------------------------------------------------------------ WB
    wb_stage u_wb (
        .clk(clk), .rst(rst),
        .memwb_valid(memwb_valid), .memwb_pc(memwb_pc), .memwb_instr(memwb_instr),
        .memwb_value(memwb_value), .memwb_dest(memwb_dest), .memwb_reg_write(memwb_reg_write),
        .memwb_exc(memwb_exc), .memwb_bad_addr(memwb_bad_addr),
        .memwb_mop(memwb_mop), .memwb_msize(memwb_msize),
        .memwb_maddr(memwb_maddr), .memwb_mdata(memwb_mdata),
        .rf_we(rf_we), .rf_waddr(rf_waddr), .rf_wdata(rf_wdata),
        .halt_now(halt_now), .stop(stop), .halted(halted),
        .halt_cause(halt_cause), .halt_pc(halt_pc), .halt_addr(halt_addr),
        .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_instr(ret_instr),
        .ret_wen(ret_wen), .ret_waddr(ret_waddr), .ret_wdata(ret_wdata),
        .ret_mem_op(ret_mem_op), .ret_mem_size(ret_mem_size),
        .ret_mem_addr(ret_mem_addr), .ret_mem_data(ret_mem_data)
    );

    // --------------------------------------------------- performance events
    // An event is only counted if its source instruction is *older* than every
    // halting instruction in flight; events from younger (doomed) instructions
    // would otherwise break the cycle-accounting identity
    //     cycles = instret + 4 + load-use stalls + squashed slots.
    wire halt_in_mem = exmem_valid & ((exmem_exc != `EXC_NONE) | mem_fault);
    wire halt_in_wb  = memwb_valid & (memwb_exc != `EXC_NONE);
    wire halt_in_ex  = idex_valid  & (idex_exc  != `EXC_NONE);
    wire en_ex = ~(halt_in_mem | halt_in_wb);              // source in EX
    wire en_id = en_ex & ~halt_in_ex;                      // source in ID

    assign evt_stall       = stall       & en_ex & ~stop;
    assign evt_ex_redirect = ex_redirect & en_ex & ~stop;
    assign evt_id_redirect = redirect_id & en_id & ~stop;
    assign evt_squash      = (ex_redirect & en_ex & ~stop) ? {1'b0, 1'b1} + {1'b0, ifid_valid} :
                             (redirect_id & en_id & ~stop) ? 2'd1 : 2'd0;
    assign evt_br          = ex_br_cond  & en_ex & ~stop;
    assign evt_br_taken    = ex_br_taken & en_ex & ~stop;
    assign evt_fwd_exmem   = idex_valid ? ({1'b0, idex_uses_rs & (fwd_a == 2'd1)} +
                                           {1'b0, idex_uses_rt & (fwd_b == 2'd1)}) : 2'd0;
    assign evt_fwd_memwb   = idex_valid ? ({1'b0, idex_uses_rs & (fwd_a == 2'd2)} +
                                           {1'b0, idex_uses_rt & (fwd_b == 2'd2)}) : 2'd0;
endmodule
`default_nettype wire
