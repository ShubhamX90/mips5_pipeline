// =============================================================================
// tb_mips -- top-level testbench shared by the pipelined and single-cycle core.
//
// Compile-time options (-D):
//   SINGLE_CYCLE      instantiate mips_single_cycle instead of mips_core
//   NO_MEM_MEM_FWD    build the pipeline without MEM->MEM store-data forwarding
//
// Run-time options (+plusargs):
//   +IMEM=<hex>       instruction memory image         (required)
//   +DMEM=<hex>       data memory image                (optional)
//   +TRACE=<file>     write the retirement trace here
//   +STATE=<file>     write the final architectural state here
//   +MAXCYC=<n>       cycle limit before declaring a timeout (default 300000)
//   +VCD=<file>       dump a waveform
//
// Machine-readable result lines on stdout (parsed by tools/regress.py):
//   RESULT halted cause=<0..3> pc=<hex> addr=<hex>   |   RESULT timeout
//   PERF <name>=<value> ...
//   ASSERT checks=<n> fails=<n>        (pipelined build only)
//   COV <bin>=<count>                  (pipelined build only)
// =============================================================================
`timescale 1ns/1ps
`include "mips_defs.vh"

module tb_mips;
    parameter IMEM_WORDS = 4096;
    parameter DMEM_WORDS = 4096;
    localparam DMEM_ADDR_BITS = $clog2(DMEM_WORDS) + 2;
`ifdef NO_MEM_MEM_FWD
    localparam MEM_MEM_FWD = 0;
`else
    localparam MEM_MEM_FWD = 1;
`endif

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // ---- DUT + memories ---------------------------------------------------------
    wire [31:0] imem_addr, imem_data, dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_we;

    wire        halted;  wire [1:0] halt_cause;  wire [31:0] halt_pc, halt_addr;
    wire        ret_valid, ret_wen;
    wire [31:0] ret_pc, ret_instr, ret_wdata, ret_mem_addr, ret_mem_data;
    wire [4:0]  ret_waddr;
    wire [1:0]  ret_mem_op, ret_mem_size;
    wire        evt_stall, evt_ex_redirect, evt_id_redirect, evt_br, evt_br_taken;
    wire [1:0]  evt_squash, evt_fwd_exmem, evt_fwd_memwb;

    imem #(.WORDS(IMEM_WORDS)) u_imem (.addr(imem_addr), .data(imem_data));
    dmem #(.WORDS(DMEM_WORDS)) u_dmem (.clk(clk), .addr(dmem_addr), .we(dmem_we),
                                       .be(dmem_be), .wdata(dmem_wdata), .rdata(dmem_rdata));

`ifdef SINGLE_CYCLE
    mips_single_cycle #(.MEM_MEM_FWD(MEM_MEM_FWD), .DMEM_ADDR_BITS(DMEM_ADDR_BITS)) u_core (
`else
    mips_core #(.MEM_MEM_FWD(MEM_MEM_FWD), .DMEM_ADDR_BITS(DMEM_ADDR_BITS)) u_core (
`endif
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata),
        .halted(halted), .halt_cause(halt_cause), .halt_pc(halt_pc), .halt_addr(halt_addr),
        .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_instr(ret_instr),
        .ret_wen(ret_wen), .ret_waddr(ret_waddr), .ret_wdata(ret_wdata),
        .ret_mem_op(ret_mem_op), .ret_mem_size(ret_mem_size),
        .ret_mem_addr(ret_mem_addr), .ret_mem_data(ret_mem_data),
        .evt_stall(evt_stall), .evt_ex_redirect(evt_ex_redirect),
        .evt_id_redirect(evt_id_redirect), .evt_squash(evt_squash),
        .evt_br(evt_br), .evt_br_taken(evt_br_taken),
        .evt_fwd_exmem(evt_fwd_exmem), .evt_fwd_memwb(evt_fwd_memwb)
    );

    wire [31:0] p_cycles, p_instret, p_stalls, p_rex, p_rid, p_squash, p_br, p_brt, p_fx, p_fm,
                p_mix_alu, p_mix_load, p_mix_store, p_mix_branch, p_mix_jump;
    perf_counters u_perf (
        .clk(clk), .rst(rst), .halted(halted),
        .ret_valid(ret_valid), .ret_instr(ret_instr),
        .evt_stall(evt_stall), .evt_ex_redirect(evt_ex_redirect), .evt_id_redirect(evt_id_redirect),
        .evt_squash(evt_squash), .evt_br(evt_br), .evt_br_taken(evt_br_taken),
        .evt_fwd_exmem(evt_fwd_exmem), .evt_fwd_memwb(evt_fwd_memwb),
        .cycles(p_cycles), .instret(p_instret), .stalls_loaduse(p_stalls),
        .redirects_ex(p_rex), .redirects_id(p_rid), .squashed(p_squash),
        .branches(p_br), .branches_taken(p_brt), .fwd_exmem(p_fx), .fwd_memwb(p_fm),
        .mix_alu(p_mix_alu), .mix_load(p_mix_load), .mix_store(p_mix_store),
        .mix_branch(p_mix_branch), .mix_jump(p_mix_jump)
    );

`ifndef SINGLE_CYCLE
    mips_assertions u_asrt ();
    mips_coverage   u_cov  ();
`endif

    // ---- run control ---------------------------------------------------------------
    integer trace_fd = 0;
    integer maxcyc;
    integer tb_cycles = 0;
    reg [1023:0] trace_name, state_name, vcd_name;
    integer i;

    initial begin
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 300000;
        if ($value$plusargs("TRACE=%s", trace_name)) trace_fd = $fopen(trace_name, "w");
        if ($value$plusargs("VCD=%s", vcd_name)) begin
            $dumpfile(vcd_name);
            $dumpvars(0, tb_mips);
        end
        repeat (4) @(posedge clk);
        #1 rst = 1'b0;
    end

    // retirement trace -- sampled at the edge, i.e. the values of the ending cycle
    always @(posedge clk) begin
        if (!rst && ret_valid && trace_fd != 0) begin
            $fdisplay(trace_fd, "%08x %08x %02d %08x %0d %0d %08x %08x",
                      ret_pc, ret_instr, ret_waddr, ret_wdata,
                      ret_mem_op,
                      (ret_mem_op == `MOP_NONE) ? 2'd0 : ret_mem_size,
                      (ret_mem_op == `MOP_NONE) ? 32'd0 : ret_mem_addr,
                      (ret_mem_op == `MOP_NONE) ? 32'd0 : ret_mem_data);
        end
    end

    task dump_state;
        integer fd, k;
        reg [1023:0] fname;
        begin
            if ($value$plusargs("STATE=%s", fname)) begin
                fd = $fopen(fname, "w");
                $fdisplay(fd, "HALT %0d %08x %08x", halt_cause, halt_pc,
                          (halt_cause == `EXC_ADDR) ? halt_addr : 32'd0);
                $fdisplay(fd, "RET %0d", p_instret);
                for (k = 0; k < 32; k = k + 1)
                    $fdisplay(fd, "REG %02d %08x", k, u_core.u_rf.regs[k]);
                for (k = 0; k < DMEM_WORDS; k = k + 1)
                    if (u_dmem.mem[k] != 32'b0)
                        $fdisplay(fd, "MEM %08x %08x", k * 4, u_dmem.mem[k]);
                $fclose(fd);
            end
        end
    endtask

    task print_summary;
        begin
            $display("PERF cycles=%0d instret=%0d stalls_loaduse=%0d redirects_ex=%0d redirects_id=%0d squashed=%0d",
                     p_cycles, p_instret, p_stalls, p_rex, p_rid, p_squash);
            $display("PERF branches=%0d branches_taken=%0d fwd_exmem=%0d fwd_memwb=%0d",
                     p_br, p_brt, p_fx, p_fm);
            $display("PERF mix_alu=%0d mix_load=%0d mix_store=%0d mix_branch=%0d mix_jump=%0d",
                     p_mix_alu, p_mix_load, p_mix_store, p_mix_branch, p_mix_jump);
`ifndef SINGLE_CYCLE
            u_asrt.report;
            u_cov.report;
`endif
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            tb_cycles = tb_cycles + 1;
            if (halted) begin
                $display("RESULT halted cause=%0d pc=%08x addr=%08x", halt_cause, halt_pc,
                         (halt_cause == `EXC_ADDR) ? halt_addr : 32'd0);
                dump_state;
                print_summary;
                if (trace_fd != 0) $fclose(trace_fd);
                $finish;
            end else if (tb_cycles >= maxcyc) begin
                $display("RESULT timeout");
                dump_state;
                print_summary;
                if (trace_fd != 0) $fclose(trace_fd);
                $finish;
            end
        end
    end
endmodule
