#!/usr/bin/env python3
"""Benchmark driver: single-cycle vs. 5-stage pipeline on 16 workloads.

For every program in bench/*.s it
  * runs the full equivalence flow of tools/regress.py (retirement trace, final
    state, assertions, cycle model, ... for all three RTL variants),
  * checks the program's result ($v0) against the native-Python golden model,
  * collects the RTL hardware counters (cycles, stalls, flushes, forwards,
    instruction mix),
  * derives CPI stacks, an analytical clock-period model, and design-space
    what-ifs from the same retired-instruction traces,
and writes docs/BENCHMARKS.md, docs/img/*.png and bench/results/results.json.

The clock-period model is ANALYTICAL (stage-delay assumptions below, adjustable
on the command line) -- it is not the result of synthesis or place-and-route.
CPI and all event counts, in contrast, are exact RTL measurements.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import asm  # noqa: E402
import golden  # noqa: E402
import iss  # noqa: E402
import perfmodel  # noqa: E402
import regress  # noqa: E402


@dataclass
class Delays:
    """Stage delays in picoseconds (assumptions, loosely a 28-45 nm-class standard-cell flow)."""
    imem: int = 250        # instruction memory read (combinational)
    rf_read: int = 100     # register-file read incl. write-through mux
    fwd_mux: int = 40      # operand forwarding mux
    alu: int = 250         # 32-bit add / compare / 32x32 MUL is *not* included (see docs)
    dmem: int = 250        # data memory read + load alignment
    rf_write: int = 100    # register-file write setup
    pc_mux: int = 40       # next-PC selection
    reg_overhead: int = 60  # clk->Q + setup for each register stage

    def single_cycle(self) -> int:
        return self.reg_overhead + self.imem + self.rf_read + self.alu + self.dmem + self.rf_write + self.pc_mux

    def pipelined(self) -> int:
        stages = {"IF": self.imem + self.pc_mux,
                  "ID": self.rf_read + self.pc_mux + 40,        # decode + hazard detect + jump target mux
                  "EX": self.fwd_mux + self.alu,                # forwarding mux in front of the ALU
                  "MEM": self.dmem,
                  "WB": self.rf_write}
        return self.reg_overhead + max(stages.values())

    def stage_table(self):
        return {"IF": self.imem + self.pc_mux, "ID": self.rf_read + self.pc_mux + 40,
                "EX": self.fwd_mux + self.alu, "MEM": self.dmem, "WB": self.rf_write}


def geomean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def run_benchmarks(jobs):
    files = sorted((ROOT / "bench").glob("*.s"))
    cases = [(f.stem, f) for f in files]
    results = regress.run_many(cases, regress.BUILD / "bench", jobs, ("pipe", "nomm", "single"))
    out = []
    for r in results:
        f = ROOT / "bench" / f"{r['name']}.s"
        ok = r["ok"]
        errs = list(r["errors"])
        prog = asm.assemble(f.read_text())
        ref = iss.run(prog.imem, prog.dmem_words(), 5_000_000)
        want = golden.GOLDEN[r["name"]]() & 0xFFFFFFFF
        got = ref.regs[2]
        if got != want:
            ok = False
            errs.append(f"result $v0=0x{got:08x} != golden 0x{want:08x}")
        entry = {"name": r["name"], "ok": ok, "errors": errs, "result": got, "golden": want,
                 "perf": {v: r["variants"][v]["perf"] for v in r["variants"]}}
        tl = {}
        for label, cfg in [("baseline", perfmodel.Config()),
                           ("no_forwarding", perfmodel.Config(forwarding="none")),
                           ("branch_in_id", perfmodel.Config(branch="id")),
                           ("btfn", perfmodel.Config(branch="btfn")),
                           ("no_mem_mem", perfmodel.Config(mem_mem_fwd=False))]:
            t = perfmodel.timeline(ref, prog.imem, cfg)
            tl[label] = {"cycles": t.cycles, "stall": t.stall_cycles, "flush": t.flush_cycles}
        entry["whatif"] = tl
        entry["taken_backward"] = sum(1 for x in ref.retired
                                      if (lambda u: u and u.is_cond_branch)(__import__("isa").usage(x.instr))
                                      and x.taken and __import__("isa").sext(x.instr & 0xFFFF, 16) < 0)
        out.append(entry)
    return out


def derive(entry, d: Delays):
    p, s = entry["perf"]["pipe"], entry["perf"]["single"]
    n = p["instret"]
    cpi = p["cycles"] / n
    t_pipe, t_single = d.pipelined(), d.single_cycle()
    entry["metrics"] = {
        "instret": n, "cycles_pipe": p["cycles"], "cycles_single": s["cycles"], "cycles_nomm": entry["perf"]["nomm"]["cycles"],
        "cpi": cpi,
        "cpi_fill": 4 / n,
        "cpi_loaduse": p["stalls_loaduse"] / n,
        "cpi_branch": (2 * p["redirects_ex"]) / n,
        "cpi_jump": p["redirects_id"] / n,
        "branch_frac": p["branches"] / n,
        "taken_frac": p["branches_taken"] / max(1, p["branches"]),
        "speedup_cycles": s["cycles"] / p["cycles"],
        "speedup_time": (s["cycles"] * t_single) / (p["cycles"] * t_pipe),
        "mm_gain": entry["perf"]["nomm"]["cycles"] / p["cycles"],
        "mix": {k[4:]: p[k] / n for k in ("mix_alu", "mix_load", "mix_store", "mix_branch", "mix_jump")},
        "fwd_per_instr": (p["fwd_exmem"] + p["fwd_memwb"]) / n,
    }
    return entry


# ----------------------------------------------------------------------------------- charts
def charts(entries, d: Delays, imgdir: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    imgdir.mkdir(parents=True, exist_ok=True)
    plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
                         "axes.grid": True, "grid.alpha": 0.25, "figure.dpi": 140})
    C = {"base": "#4C72B0", "fill": "#B0B7C3", "load": "#DD8452", "branch": "#C44E52", "jump": "#8172B3",
         "alu": "#4C72B0", "mem": "#55A868", "st": "#CCB974"}
    names = [e["name"] for e in entries]
    x = range(len(entries))

    # 1. CPI stack
    fig, ax = plt.subplots(figsize=(10, 4.2))
    bottom = [0] * len(entries)
    for key, col, lab in [("base", C["base"], "ideal (1.0)"), ("cpi_fill", C["fill"], "pipeline fill"),
                          ("cpi_loaduse", C["load"], "load-use stalls"),
                          ("cpi_branch", C["branch"], "taken branch / jr flush (2 cycles)"),
                          ("cpi_jump", C["jump"], "j / jal flush (1 cycle)")]:
        vals = [1.0 if key == "base" else e["metrics"][key] for e in entries]
        ax.bar(x, vals, bottom=bottom, color=col, label=lab, width=0.7)
        bottom = [b + v for b, v in zip(bottom, vals)]
    for i, e in enumerate(entries):
        ax.text(i, bottom[i] + 0.02, f"{e['metrics']['cpi']:.2f}", ha="center", fontsize=8)
    ax.set_ylim(0, max(bottom) * 1.1)
    ax.set_xticks(list(x)); ax.set_xticklabels(names, rotation=40, ha="right")
    ax.set_ylabel("cycles per instruction"); ax.set_title("Pipeline CPI stack (measured RTL counters)")
    ax.legend(ncol=3, fontsize=8, frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.38))
    fig.tight_layout(); fig.savefig(imgdir / "cpi_stack.png", bbox_inches="tight"); plt.close(fig)

    # 2. speedup
    fig, ax = plt.subplots(figsize=(10, 3.8))
    sp = [e["metrics"]["speedup_time"] for e in entries]
    ax.bar(x, sp, color=C["base"], width=0.7)
    ax.axhline(1.0, color="k", lw=0.8)
    gm = geomean(sp)
    ax.axhline(gm, color=C["branch"], lw=1.2, ls="--", label=f"geometric mean {gm:.2f}x")
    ax.axhline(d.single_cycle() / d.pipelined(), color="#888", lw=1, ls=":", label=f"ideal (clock ratio) {d.single_cycle()/d.pipelined():.2f}x")
    for i, v in enumerate(sp):
        ax.text(i, v + 0.03, f"{v:.2f}", ha="center", fontsize=8)
    ax.set_ylim(0, max(sp) * 1.15)
    ax.set_xticks(list(x)); ax.set_xticklabels(names, rotation=40, ha="right")
    ax.set_ylabel("speedup over single-cycle"); ax.set_title(
        f"Execution-time speedup  (single-cycle {d.single_cycle()} ps vs pipelined {d.pipelined()} ps clock — analytical model)")
    ax.legend(frameon=False); fig.tight_layout(); fig.savefig(imgdir / "speedup.png", bbox_inches="tight"); plt.close(fig)

    # 3. what-if
    fig, ax = plt.subplots(figsize=(10, 4.2))
    cfgs = [("baseline", "this design", C["base"]), ("no_mem_mem", "no MEM→MEM fwd", C["st"]),
            ("branch_in_id", "branch resolved in ID", C["mem"]), ("btfn", "static BTFN predictor", C["jump"]),
            ("no_forwarding", "no forwarding", C["branch"])]
    w = 0.16
    for k, (key, lab, col) in enumerate(cfgs):
        vals = [e["whatif"][key]["cycles"] / e["metrics"]["instret"] for e in entries]
        ax.bar([i + (k - 2) * w for i in x], vals, w, label=lab, color=col)
    ax.set_xticks(list(x)); ax.set_xticklabels(names, rotation=40, ha="right")
    ax.set_ylabel("CPI"); ax.set_title("Design-space what-ifs from the same instruction traces (trace-driven timeline model)")
    ax.legend(ncol=5, fontsize=8, frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.38))
    fig.tight_layout(); fig.savefig(imgdir / "whatif.png", bbox_inches="tight"); plt.close(fig)

    # 4. instruction mix
    fig, ax = plt.subplots(figsize=(10, 3.8))
    bottom = [0] * len(entries)
    for key, col, lab in [("alu", C["alu"], "ALU / other"), ("load", C["mem"], "loads"), ("store", C["st"], "stores"),
                          ("branch", C["branch"], "cond. branches"), ("jump", C["jump"], "jumps")]:
        vals = [e["metrics"]["mix"][key] for e in entries]
        ax.bar(x, vals, bottom=bottom, color=col, label=lab, width=0.7)
        bottom = [b + v for b, v in zip(bottom, vals)]
    ax.set_xticks(list(x)); ax.set_xticklabels(names, rotation=40, ha="right")
    ax.set_ylabel("fraction of retired instructions"); ax.set_title("Dynamic instruction mix")
    ax.legend(ncol=5, fontsize=8, frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.38))
    fig.tight_layout(); fig.savefig(imgdir / "mix.png", bbox_inches="tight"); plt.close(fig)

    # 5. stage delay / clock model
    fig, ax = plt.subplots(figsize=(6.5, 3.2))
    st = d.stage_table()
    ax.bar(list(st), list(st.values()), color=[C["base"]] * 5)
    ax.axhline(max(st.values()), color=C["branch"], ls="--", lw=1)
    ax.text(4.45, max(st.values()) + 6, f"critical stage → T = {d.pipelined()} ps", ha="right", fontsize=8, color=C["branch"])
    ax.set_ylabel("ps"); ax.set_title("Assumed stage delays (pipelined)")
    fig.tight_layout(); fig.savefig(imgdir / "stage_delays.png", bbox_inches="tight"); plt.close(fig)


# ----------------------------------------------------------------------------------- report
def report(entries, d: Delays, path: Path):
    m = [e["metrics"] for e in entries]
    tot_n = sum(x["instret"] for x in m)
    tot_c = sum(x["cycles_pipe"] for x in m)
    gm_sp = geomean([x["speedup_time"] for x in m])
    gm_cyc = geomean([x["speedup_cycles"] for x in m])
    worst = max(entries, key=lambda e: e["metrics"]["cpi"])
    best = min(entries, key=lambda e: e["metrics"]["cpi"])
    L = []
    A = L.append
    A("# Benchmarks: single-cycle vs. 5-stage pipeline\n")
    A("_Generated by `tools/bench.py` — do not edit by hand. Re-run with `make bench`._\n")
    A("Everything in the **cycle** columns is measured on the RTL (hardware counters), after the full "
      "equivalence flow (retirement trace + final state against the ISS, SVA assertions, cycle model) passed for "
      "all three RTL variants and `$v0` matched an independent native-Python result. "
      "The **time** columns apply an *analytical* clock model (below); they are not synthesis results.\n")
    A("## Summary\n")
    A(f"* 16 workloads, {tot_n:,} retired instructions, {tot_c:,} pipeline cycles (aggregate CPI **{tot_c/tot_n:.3f}**).")
    A(f"* Lowest CPI: `{best['name']}` ({best['metrics']['cpi']:.3f}); highest: `{worst['name']}` ({worst['metrics']['cpi']:.3f}).")
    A(f"* In cycles alone the pipeline is *slower* than the single-cycle core by {geomean([1/x['speedup_cycles'] for x in m]):.2f}x "
      f"(geomean) — that is the price of hazards; it buys a {d.single_cycle()/d.pipelined():.2f}x shorter clock.")
    A(f"* Net execution-time speedup under the clock model: **{gm_sp:.2f}x geometric mean** "
      f"(range {min(x['speedup_time'] for x in m):.2f}x – {max(x['speedup_time'] for x in m):.2f}x).\n")
    A("## Per-benchmark results\n")
    A("| benchmark | instr | cycles (single) | cycles (pipe) | CPI | load-use stalls | EX flush cycles | ID flush cycles | cond. branches (taken) | speedup (time) |")
    A("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for e in entries:
        p = e["perf"]["pipe"]; x = e["metrics"]
        A(f"| `{e['name']}` | {x['instret']:,} | {x['cycles_single']:,} | {x['cycles_pipe']:,} | {x['cpi']:.3f} | "
          f"{p['stalls_loaduse']:,} | {2*p['redirects_ex']:,} | {p['redirects_id']:,} | "
          f"{p['branches']:,} ({100*x['taken_frac']:.0f}%) | {x['speedup_time']:.2f}x |")
    A("")
    A("![CPI stack](img/cpi_stack.png)\n")
    A("The CPI stack is exact: `cycles = instret + 4 (fill) + load-use stalls + 2·(taken branch/jr) + 1·(j/jal)`, "
      "an identity the regression asserts for every program.\n")
    A("## Where do the stalls come from?\n")
    A("| benchmark | dominant loss | loss CPI | comment |")
    A("|---|---|---:|---|")
    notes = {
        "linked_list": "pointer chasing: every `lw` address depends on the previous `lw` → one load-use bubble per hop.",
        "fib_recursive": "call/return: `lw $ra; jr $ra` pairs, plus data-dependent recursion and the `jal` redirect.",
        "mini_vm": "the dispatch chain `lbu→sll→lw→jr` costs a load-use bubble + a 2-cycle `jr` flush per bytecode.",
        "collatz": "random-parity branch plus unconditional back-edge `b`: ~2–3 flush cycles per step.",
        "gcd": "subtract loop: direction of the compare flips unpredictably; every taken edge is a 2-cycle flush.",
        "bubble_sort": "data-dependent swap branch and the load→compare→branch chain.",
        "insertion_sort": "inner-loop exit branch and the unconditional back-edge.",
        "crc32": "1024 data-dependent bit branches, half taken.",
        "matmul": "load-use into MUL inside the k-loop; branch loss small (8-iteration loops).",
        "saxpy": "only load-use into MUL/add; one well-behaved loop branch.",
        "memcpy_strlen": "`lbu → beq` load-use per byte plus taken back-edges.",
        "binary_search": "load→compare→three-way branch per probe.",
        "popcount": "3-instruction dependent loop with a taken back-edge every iteration.",
        "sieve": "short inner loops, byte stores; back-edge flushes dominate.",
        "fib_iter": "single dependent ALU chain (fully forwarded) + one taken back-edge per 5 instructions.",
        "factorial": "MUL→MUL forwarding is free; loop back-edges only.",
    }
    for e in entries:
        x = e["metrics"]
        comp = {"load-use": x["cpi_loaduse"], "branch/jr flush": x["cpi_branch"], "jump flush": x["cpi_jump"]}
        k = max(comp, key=comp.get)
        A(f"| `{e['name']}` | {k} | {comp[k]:.3f} | {notes.get(e['name'], '')} |")
    A("")
    A("## Execution-time model (analytical)\n")
    st = d.stage_table()
    A("Stage delay assumptions (ps): " + ", ".join(f"{k} {v}" for k, v in st.items()) + f"; register overhead {d.reg_overhead}.\n")
    A(f"* **Pipelined clock** = overhead + slowest stage = {d.reg_overhead} + {max(st.values())} = **{d.pipelined()} ps** (EX: forwarding mux + ALU).")
    A(f"* **Single-cycle clock** = overhead + IMEM + RF read + ALU + DMEM + RF write + PC mux = **{d.single_cycle()} ps**.")
    A(f"* Ideal pipelining gain = {d.single_cycle()/d.pipelined():.2f}x; realised = ideal / CPI. "
      f"Change the assumptions with `python3 tools/bench.py --imem 300 --alu 400 ...`.\n")
    A("![Speedup](img/speedup.png)\n")
    A("![Stage delays](img/stage_delays.png)\n")
    A("Sensitivity of the geometric-mean speedup to the pipelined clock period:\n")
    A("| pipelined T (ps) | " + " | ".join(str(t) for t in (250, 300, 350, 400, 450, 500)) + " |")
    A("|---|" + "---:|" * 6)
    row = []
    for t in (250, 300, 350, 400, 450, 500):
        row.append(f"{geomean([ (x['cycles_single']*d.single_cycle())/(x['cycles_pipe']*t) for x in m]):.2f}x")
    A("| geomean speedup | " + " | ".join(row) + " |\n")
    A("## Design-space what-ifs\n")
    A("The ISS retirement trace fully determines the instruction stream, so alternative hazard policies can be "
      "evaluated with a trace-driven timeline model (`tools/perfmodel.py`). The model is *validated* by "
      "reproducing the RTL's exact cycle count for the baseline on every test program in the regression; "
      "the alternatives are model predictions, not RTL.\n")
    A("![What-ifs](img/whatif.png)\n")
    A("| benchmark | CPI this design | no MEM→MEM fwd (RTL) | branch in ID | static BTFN | no forwarding |")
    A("|---|---:|---:|---:|---:|---:|")
    for e in entries:
        n = e["metrics"]["instret"]; w = e["whatif"]
        A(f"| `{e['name']}` | {w['baseline']['cycles']/n:.3f} | {e['metrics']['cycles_nomm']/n:.3f} | "
          f"{w['branch_in_id']['cycles']/n:.3f} | {w['btfn']['cycles']/n:.3f} | {w['no_forwarding']['cycles']/n:.3f} |")
    agg = lambda key: sum(e["whatif"][key]["cycles"] for e in entries) / tot_n  # noqa: E731
    A(f"| **aggregate** | **{agg('baseline'):.3f}** | **{sum(x['cycles_nomm'] for x in m)/tot_n:.3f}** | "
      f"**{agg('branch_in_id'):.3f}** | **{agg('btfn'):.3f}** | **{agg('no_forwarding'):.3f}** |\n")
    A("Take-aways: forwarding is worth "
      f"{100*(agg('no_forwarding')/agg('baseline')-1):.0f}% in cycles; MEM→MEM store-data forwarding is worth "
      f"{100*(sum(x['cycles_nomm'] for x in m)/tot_c-1):.1f}%; a static backward-taken predictor would save "
      f"{100*(1-agg('btfn')/agg('baseline')):.1f}% of cycles; resolving branches in ID (with the extra operand-forwarding hardware that implies) "
      f"{100*(1-agg('branch_in_id')/agg('baseline')):.1f}%.\n")
    A("## Instruction mix\n")
    A("![Mix](img/mix.png)\n")
    A("| benchmark | ALU/other | loads | stores | branches | jumps | fwd EX/MEM+MEM/WB per instr |")
    A("|---|---:|---:|---:|---:|---:|---:|")
    for e in entries:
        x = e["metrics"]; mx = x["mix"]
        A(f"| `{e['name']}` | {100*mx['alu']:.1f}% | {100*mx['load']:.1f}% | {100*mx['store']:.1f}% | "
          f"{100*mx['branch']:.1f}% | {100*mx['jump']:.1f}% | {x['fwd_per_instr']:.2f} |")
    A("")
    A("## Reproduce\n")
    A("```bash\nmake bench\n```\n")
    path.write_text("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    d0 = Delays()
    for k, v in asdict(d0).items():
        ap.add_argument(f"--{k.replace('_', '-')}", type=int, default=v)
    args = ap.parse_args()
    d = Delays(**{k: getattr(args, k) for k in asdict(d0)})

    subprocess.run(["make", "-s", "-C", str(ROOT), "sims"], check=True)
    entries = [derive(e, d) for e in run_benchmarks(args.jobs)]

    print(f"{'benchmark':<16}{'instr':>8}{'single':>9}{'pipe':>9}{'CPI':>7}{'ldst':>7}{'flush':>7}{'speedup':>9}  status")
    print("-" * 82)
    for e in entries:
        m, p = e["metrics"], e["perf"]["pipe"]
        print(f"{e['name']:<16}{m['instret']:>8}{m['cycles_single']:>9}{m['cycles_pipe']:>9}{m['cpi']:>7.3f}"
              f"{p['stalls_loaduse']:>7}{2*p['redirects_ex']+p['redirects_id']:>7}{m['speedup_time']:>8.2f}x  "
              f"{'PASS' if e['ok'] else 'FAIL'}")
        for err in e["errors"]:
            print(f"      ! {err}")
    bad = [e for e in entries if not e["ok"]]
    tot_n = sum(e["metrics"]["instret"] for e in entries)
    tot_c = sum(e["metrics"]["cycles_pipe"] for e in entries)
    print(f"\naggregate CPI {tot_c/tot_n:.3f}; geomean speedup (time model) "
          f"{geomean([e['metrics']['speedup_time'] for e in entries]):.2f}x")
    if bad:
        print("BENCHMARKS FAILED")
        return 1
    (ROOT / "bench" / "results").mkdir(exist_ok=True)
    (ROOT / "bench" / "results" / "results.json").write_text(json.dumps(
        {"delays_ps": asdict(d), "pipelined_clock_ps": d.pipelined(), "single_cycle_clock_ps": d.single_cycle(),
         "benchmarks": entries}, indent=1))
    charts(entries, d, ROOT / "docs" / "img")
    report(entries, d, ROOT / "docs" / "BENCHMARKS.md")
    print("wrote docs/BENCHMARKS.md, docs/img/*.png, bench/results/results.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
