`default_nettype none
`include "mips_defs.vh"
// =============================================================================
// mem_stage -- Memory access.  Owns the MEM/WB pipeline register.
//
// * Address faults (misaligned, or outside the data memory) suppress the
//   access and tag the instruction EXC_ADDR; the core halts when it reaches
//   write-back.
// * `stop` also suppresses the store: a store younger than a halting
//   instruction must never reach memory.
// * Load data is aligned/extended here, so MEM/WB carries the final
//   write-back value (`memwb_value`) for every instruction type.
// * MEM->MEM store-data forwarding (MEM_MEM_FWD=1): if the instruction one
//   place ahead (now in MEM/WB) produces the store's rt, its write-back value
//   replaces the stale rt captured in EX.  This is what lets `lw; sw` with the
//   loaded value as store data run without a load-use stall.
//   By the time-ordering argument in docs/HAZARDS.md, MEM/WB always holds the
//   *immediately preceding* instruction, so a match is always the youngest
//   writer.
// =============================================================================
module mem_stage #(
    parameter MEM_MEM_FWD = 1,
    parameter DMEM_ADDR_BITS = 14
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        stop,

    // EX/MEM
    input  wire        exmem_valid,
    input  wire [31:0] exmem_pc,
    input  wire [31:0] exmem_instr,
    input  wire [31:0] exmem_result,
    input  wire [31:0] exmem_rt_val,
    input  wire [4:0]  exmem_rt,
    input  wire [4:0]  exmem_dest,
    input  wire        exmem_reg_write,
    input  wire        exmem_mem_read,
    input  wire        exmem_mem_write,
    input  wire [1:0]  exmem_mem_size,
    input  wire        exmem_mem_signed,
    input  wire [1:0]  exmem_exc,

    // data memory port
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_be,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,

    // for MEM->MEM forwarding / fault visibility
    output wire        mem_fault,         // address fault raised by the instruction in MEM
    output wire        st_fwd,            // store data replaced from MEM/WB

    // MEM/WB pipeline register
    output reg         memwb_valid,
    output reg  [31:0] memwb_pc,
    output reg  [31:0] memwb_instr,
    output reg  [31:0] memwb_value,       // value to write to the register file
    output reg  [4:0]  memwb_dest,
    output reg         memwb_reg_write,
    output reg  [1:0]  memwb_exc,
    output reg  [31:0] memwb_bad_addr,
    output reg  [1:0]  memwb_mop,         // retirement trace: MOP_*
    output reg  [1:0]  memwb_msize,
    output reg  [31:0] memwb_maddr,
    output reg  [31:0] memwb_mdata
);
    wire is_mem = exmem_valid & (exmem_mem_read | exmem_mem_write);
    wire fault_c;
    mem_check #(.ADDR_BITS(DMEM_ADDR_BITS)) u_chk (
        .addr(exmem_result), .size(exmem_mem_size), .fault(fault_c));
    assign mem_fault = is_mem & fault_c;

    // ---- store data (with optional MEM->MEM bypass) ---------------------------
    assign st_fwd = (MEM_MEM_FWD != 0) & exmem_valid & exmem_mem_write &
                    memwb_valid & memwb_reg_write & (memwb_exc == `EXC_NONE) &
                    (memwb_dest != 5'd0) & (memwb_dest == exmem_rt);
    wire [31:0] store_val = st_fwd ? memwb_value : exmem_rt_val;

    store_fmt u_sf (.data(store_val), .byte_off(exmem_result[1:0]),
                    .size(exmem_mem_size), .wdata(dmem_wdata), .be(dmem_be));

    assign dmem_addr = exmem_result;
    assign dmem_we   = exmem_valid & exmem_mem_write & ~fault_c & ~stop;

    // ---- load data -------------------------------------------------------------
    wire [31:0] load_val;
    load_fmt u_lf (.word(dmem_rdata), .byte_off(exmem_result[1:0]),
                   .size(exmem_mem_size), .sign_ext(exmem_mem_signed), .value(load_val));

    wire [31:0] st_masked = (exmem_mem_size == `SZ_B) ? {24'b0, store_val[7:0]}  :
                            (exmem_mem_size == `SZ_H) ? {16'b0, store_val[15:0]} : store_val;

    always @(posedge clk) begin
        if (rst || stop || !exmem_valid) begin
            memwb_valid     <= 1'b0;
            memwb_pc        <= 32'b0;
            memwb_instr     <= `NOP_INSTR;
            memwb_value     <= 32'b0;
            memwb_dest      <= 5'd0;
            memwb_reg_write <= 1'b0;
            memwb_exc       <= `EXC_NONE;
            memwb_bad_addr  <= 32'b0;
            memwb_mop       <= `MOP_NONE;
            memwb_msize     <= `SZ_W;
            memwb_maddr     <= 32'b0;
            memwb_mdata     <= 32'b0;
        end else begin
            memwb_valid     <= 1'b1;
            memwb_pc        <= exmem_pc;
            memwb_instr     <= exmem_instr;
            memwb_value     <= exmem_mem_read ? load_val : exmem_result;
            memwb_dest      <= exmem_dest;
            memwb_reg_write <= exmem_reg_write & ~mem_fault;
            memwb_exc       <= mem_fault ? `EXC_ADDR : exmem_exc;
            memwb_bad_addr  <= exmem_result;
            memwb_mop       <= exmem_mem_read  ? `MOP_LOAD  :
                               exmem_mem_write ? `MOP_STORE : `MOP_NONE;
            memwb_msize     <= exmem_mem_size;
            memwb_maddr     <= exmem_result;
            memwb_mdata     <= exmem_mem_read ? load_val : st_masked;
        end
    end
endmodule
`default_nettype wire
