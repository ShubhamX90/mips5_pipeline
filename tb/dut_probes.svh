// =============================================================================
// dut_probes.svh -- short local aliases for pipelined-core internals.
// Included inside the assertion and coverage modules so both observe the DUT
// through hierarchical references only (no changes to the RTL ports).
// All signals are *sampled at the rising clock edge* by the users of this
// file, i.e. they hold the values of the cycle that is ending.
// =============================================================================
`define DUT tb_mips.u_core

wire        clk          = tb_mips.clk;
wire        rst          = tb_mips.rst;
wire [31:0] MM           = tb_mips.MEM_MEM_FWD;

wire        stop         = `DUT.stop;
wire        halted       = `DUT.halted;
wire        halt_now     = `DUT.halt_now;
wire [1:0]  halt_cause   = `DUT.halt_cause;

wire        stall        = `DUT.stall;
wire        load_use     = `DUT.load_use;
wire        flush_ifid   = `DUT.flush_ifid;
wire        flush_idex   = `DUT.flush_idex;
wire        redirect_id  = `DUT.redirect_id;
wire        ex_redirect  = `DUT.ex_redirect;
wire [31:0] ex_target    = `DUT.ex_target;
wire        ex_br_cond   = `DUT.ex_br_cond;
wire        ex_br_taken  = `DUT.ex_br_taken;
wire [1:0]  fwd_a        = `DUT.fwd_a;
wire [1:0]  fwd_b        = `DUT.fwd_b;

wire [31:0] imem_addr    = `DUT.imem_addr;
wire        ifid_valid   = `DUT.ifid_valid;
wire [31:0] ifid_pc      = `DUT.ifid_pc;
wire [31:0] ifid_instr   = `DUT.ifid_instr;

wire [4:0]  id_rs        = `DUT.id_rs;
wire [4:0]  id_rt        = `DUT.id_rt;
wire        id_uses_rs   = `DUT.id_uses_rs;
wire        id_uses_rt   = `DUT.id_uses_rt;
wire        id_is_store  = `DUT.id_is_store;
wire        id_jump      = `DUT.id_jump;
wire [31:0] id_jump_target = `DUT.id_jump_target;
wire [2:0]  id_br_type   = `DUT.u_id.d_br_type;
wire        id_is_jr     = `DUT.u_id.d_is_jr;
wire        id_is_link   = `DUT.u_id.d_is_link;
wire        id_mem_read  = `DUT.u_id.d_mem_read;
wire [1:0]  id_exc       = `DUT.u_id.d_exc;

wire        idex_valid   = `DUT.idex_valid;
wire [31:0] idex_instr   = `DUT.idex_instr;
wire [4:0]  idex_rs      = `DUT.idex_rs;
wire [4:0]  idex_rt      = `DUT.idex_rt;
wire        idex_uses_rs = `DUT.idex_uses_rs;
wire        idex_uses_rt = `DUT.idex_uses_rt;
wire [4:0]  idex_dest    = `DUT.idex_dest;
wire        idex_reg_write = `DUT.idex_reg_write;
wire        idex_mem_read  = `DUT.idex_mem_read;
wire        idex_mem_write = `DUT.idex_mem_write;
wire [2:0]  idex_br_type = `DUT.idex_br_type;
wire        idex_is_jr   = `DUT.idex_is_jr;
wire        idex_is_link = `DUT.idex_is_link;
wire [3:0]  idex_alu_op  = `DUT.idex_alu_op;
wire [1:0]  idex_exc     = `DUT.idex_exc;
wire [31:0] idex_br_target = `DUT.idex_br_target;

wire        exmem_valid  = `DUT.exmem_valid;
wire [31:0] exmem_instr  = `DUT.exmem_instr;
wire [4:0]  exmem_dest   = `DUT.exmem_dest;
wire [4:0]  exmem_rt     = `DUT.exmem_rt;
wire        exmem_reg_write = `DUT.exmem_reg_write;
wire        exmem_mem_read  = `DUT.exmem_mem_read;
wire        exmem_mem_write = `DUT.exmem_mem_write;
wire [1:0]  exmem_mem_size  = `DUT.exmem_mem_size;
wire [1:0]  exmem_exc    = `DUT.exmem_exc;
wire        mem_fault    = `DUT.mem_fault;
wire        st_fwd       = `DUT.st_fwd;

wire        memwb_valid  = `DUT.memwb_valid;
wire [31:0] memwb_instr  = `DUT.memwb_instr;
wire [4:0]  memwb_dest   = `DUT.memwb_dest;
wire        memwb_reg_write = `DUT.memwb_reg_write;
wire [1:0]  memwb_exc    = `DUT.memwb_exc;

wire        rf_we        = `DUT.rf_we;
wire [4:0]  rf_waddr     = `DUT.rf_waddr;
wire [4:0]  rf_raddr1    = `DUT.rf_raddr1;
wire [4:0]  rf_raddr2    = `DUT.rf_raddr2;

wire        dmem_we      = `DUT.dmem_we;
wire [3:0]  dmem_be      = `DUT.dmem_be;

wire        ret_valid    = `DUT.ret_valid;
wire [31:0] ret_pc       = `DUT.ret_pc;
wire [31:0] ret_instr    = `DUT.ret_instr;
