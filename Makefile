# =============================================================================
# MIPS-5 pipelined core -- build / verification / benchmarking driver
#
#   make            build all simulators and run the full regression
#   make sims       compile the three simulator variants
#   make lint       strict Verilog-2005 elaboration of the RTL
#   make tooltest   unit tests of the assembler / ISS / perf model
#   make test       tool tests + directed tests  (tests/asm/*.s)
#   make random     constrained-random sweep     (RANDOM_SEEDS=N, default 200)
#   make bench      benchmark suite + report     (docs/BENCHMARKS.md, bench/results)
#   make regress    test + random + bench with cross-checks
#   make mutation   inject 71 RTL bugs, confirm the regression kills each (docs/MUTATION.md)
#   make pipeview T=file.s   stage-occupancy diagram of a program on the RTL
#   make wave T=tests/asm/05_raw_forward_exmem.s   run one program, dump VCD
#   make clean
#
# Simulator variants (build/):
#   sim_pipe.vvp       pipelined core, MEM->MEM store forwarding ON  (default)
#   sim_pipe_nomm.vvp  pipelined core, MEM->MEM store forwarding OFF
#   sim_single.vvp     single-cycle baseline
# =============================================================================
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL      := $(wildcard rtl/*.v)
TB       := tb/tb_mips.sv tb/mips_assertions.sv tb/mips_coverage.sv
IVFLAGS  := -g2012 -Wall -Wno-timescale -I rtl -I tb -s tb_mips
RANDOM_SEEDS ?= 200

.PHONY: all sims lint tooltest test random bench regress mutation pipeview wave clean
all: regress

build/sim_pipe.vvp: $(RTL) $(TB) tb/dut_probes.svh | build
	$(IVERILOG) $(IVFLAGS) -o $@ $(RTL) $(TB)

build/sim_pipe_nomm.vvp: $(RTL) $(TB) tb/dut_probes.svh | build
	$(IVERILOG) $(IVFLAGS) -DNO_MEM_MEM_FWD -o $@ $(RTL) $(TB)

build/sim_single.vvp: $(RTL) tb/tb_mips.sv | build
	$(IVERILOG) $(IVFLAGS) -DSINGLE_CYCLE -o $@ $(RTL) tb/tb_mips.sv

build:
	mkdir -p build

sims: build/sim_pipe.vvp build/sim_pipe_nomm.vvp build/sim_single.vvp

lint:
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I rtl -s mips_core -o /dev/null $(RTL)
	$(IVERILOG) -g2005 -Wall -Wno-timescale -I rtl -s mips_single_cycle -o /dev/null $(RTL)
	@echo "lint: RTL elaborates cleanly as Verilog-2005"

tooltest:
	$(PYTHON) tests/test_tools.py

test: sims tooltest
	$(PYTHON) tools/regress.py directed

random: sims
	$(PYTHON) tools/regress.py random --seeds $(RANDOM_SEEDS)

bench: sims
	$(PYTHON) tools/bench.py

regress: lint sims tooltest
	$(PYTHON) tools/regress.py all --seeds $(RANDOM_SEEDS)
	$(PYTHON) tools/bench.py

mutation: sims
	$(PYTHON) tools/mutation.py --seeds 50

T ?= tests/asm/05_raw_forward_exmem.s
pipeview: sims
	$(PYTHON) tools/pipeview.py $(T) --cycles 40

wave: build/sim_pipe.vvp
	$(PYTHON) tools/asm.py $(T) -o build/wave/prog
	$(VVP) build/sim_pipe.vvp +IMEM=build/wave/prog.imem.hex +DMEM=build/wave/prog.dmem.hex \
	    +TRACE=build/wave/trace.txt +VCD=build/wave/wave.vcd
	@echo "waveform: build/wave/wave.vcd"

clean:
	rm -rf build
