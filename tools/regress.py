#!/usr/bin/env python3
"""Regression driver.

For every program (directed .s tests, or constrained-random programs) it:
  1. assembles it,
  2. runs the Python ISS (golden model),
  3. runs three RTL simulators: pipelined, pipelined w/o MEM->MEM forwarding,
     and the single-cycle baseline,
  4. requires, for every RTL variant, a byte-identical *retirement trace* and
     *final architectural state* (registers, halt cause/PC, data memory),
  5. requires zero SystemVerilog assertion failures on the pipelined builds,
  6. requires the RTL cycle count and stall/flush decomposition to equal the
     analytical performance model's prediction, and the hardware identity
         cycles = instret + 4 + load-use stalls + squashed slots (+1 if the
                  halt was a non-retiring fault),
  7. for self-checking tests, requires the in-program checks to have passed
     ($k0 == 0x600D) -- an oracle independent of both ISS and RTL,
  8. merges functional-coverage counters and reports holes.

Usage:
  regress.py directed [--filter SUBSTR]
  regress.py random   [--seeds N] [--start S] [--length L]
  regress.py all      [--seeds N]
  regress.py one FILE.s [--keep]
Exit status is non-zero on any failure.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import asm  # noqa: E402
import isa  # noqa: E402
import iss  # noqa: E402
import perfmodel  # noqa: E402

BUILD = ROOT / "build"
VARIANTS = {"pipe": BUILD / "sim_pipe.vvp",
            "nomm": BUILD / "sim_pipe_nomm.vvp",
            "single": BUILD / "sim_single.vvp"}
PASS_CODE = 0x600D
CAUSE = {"break": 1, "illegal": 2, "addr": 3}

# Coverage bins that cannot be hit in a given configuration.
COV_ONLY_WITHOUT_MM = {"stall_for_store_data"}
COV_ONLY_WITH_MM = {"load_store_data_nostall", "st_fwd_mem_mem"}


# ----------------------------------------------------------------------------------
def parse_meta(text: str) -> dict:
    meta = {"cause": "break", "selfcheck": True, "maxcyc": 300000}
    for line in text.splitlines():
        m = re.match(r"^\s*#!\s*(\w[\w-]*)\s*(?:=|\s)\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key == "expect-cause":
            meta["cause"] = val
        elif key == "no-selfcheck":
            meta["selfcheck"] = False
        elif key == "max-cycles":
            meta["maxcyc"] = int(val)
    return meta


def run_sim(variant: str, work: Path, maxcyc: int) -> dict:
    out = {"variant": variant}
    cmd = ["vvp", str(VARIANTS[variant]),
           f"+IMEM={work/'prog.imem.hex'}", f"+DMEM={work/'prog.dmem.hex'}",
           f"+TRACE={work/(variant+'.trace')}", f"+STATE={work/(variant+'.state')}",
           f"+MAXCYC={maxcyc}"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
    txt = p.stdout
    (work / f"{variant}.log").write_text(txt + p.stderr)
    out["returncode"] = p.returncode
    out["perf"] = {}
    out["cov"] = {}
    out["assert_fails"] = []
    out["assert_checks"] = 0
    for line in txt.splitlines():
        if line.startswith("RESULT"):
            out["result"] = line
            m = re.match(r"RESULT halted cause=(\d+) pc=([0-9a-f]+) addr=([0-9a-f]+)", line)
            out["halted"] = bool(m)
            if m:
                out["cause"] = int(m.group(1))
        elif line.startswith("PERF"):
            for kv in line.split()[1:]:
                k, v = kv.split("=")
                out["perf"][k] = int(v)
        elif line.startswith("COV "):
            k, v = line[4:].split("=")
            out["cov"][k] = int(v)
        elif line.startswith("ASSERT FAIL"):
            out["assert_fails"].append(line)
        elif line.startswith("ASSERT checks"):
            m = re.match(r"ASSERT checks=(\d+) fails=(\d+)", line)
            out["assert_checks"] = int(m.group(1))
    if "result" not in out:
        out["halted"] = False
        out["result"] = "NO RESULT (simulator crashed?)\n" + txt[-500:] + p.stderr[-500:]
    return out


def first_trace_diff(ref: List[str], got: List[str]) -> Optional[str]:
    for i in range(max(len(ref), len(got))):
        a = ref[i] if i < len(ref) else "<end of trace>"
        b = got[i] if i < len(got) else "<end of trace>"
        if a != b:
            def dis(line):
                try:
                    pc, ins = line.split()[:2]
                    return f"{line}   ; {isa.disasm(int(ins, 16), int(pc, 16))}"
                except Exception:  # noqa: BLE001
                    return line
            return (f"first mismatch at retired instruction #{i}\n"
                    f"      ISS: {dis(a)}\n      RTL: {dis(b)}")
    return None


def run_case(name: str, src: Path, work_root: Path, variants=("pipe", "nomm", "single")) -> dict:
    """Run one program through the whole flow.  Returns a result dict."""
    work = work_root / name
    work.mkdir(parents=True, exist_ok=True)
    res = {"name": name, "src": str(src), "ok": True, "errors": [], "variants": {}}

    def fail(msg):
        res["ok"] = False
        res["errors"].append(msg)

    text = src.read_text()
    meta = parse_meta(text)
    try:
        prog = asm.assemble(text)
    except asm.AsmError as e:
        fail(f"assembler: {e}")
        return res
    asm.write_outputs(prog, work / "prog")

    ref = iss.run(prog.imem, prog.dmem_words(), max_steps=meta["maxcyc"])
    if ref.timed_out:
        fail("ISS did not halt (infinite loop?)")
        return res
    (work / "iss.trace").write_text("".join(t + "\n" for t in ref.trace))
    (work / "iss.state").write_text(ref.state_dump())
    res["iss_instret"] = ref.instret
    res["cause"] = isa.EXC_NAMES[ref.cause]
    res["mix"] = {}

    if isa.EXC_NAMES[ref.cause] != meta["cause"]:
        fail(f"ISS halted with '{isa.EXC_NAMES[ref.cause]}', test expects '{meta['cause']}'")
    if meta["selfcheck"] and ref.cause == isa.EXC_BREAK:
        if ref.regs[26] != PASS_CODE:
            fail(f"self-check failed: $k0=0x{ref.regs[26]:04x}, failing check id $k1={ref.regs[27]}")

    ref_trace = ref.trace
    ref_state = (work / "iss.state").read_text()
    maxcyc = max(50000, 12 * ref.instret + 1000)

    for v in variants:
        r = run_sim(v, work, maxcyc)
        res["variants"][v] = r
        if not r.get("halted"):
            fail(f"[{v}] simulation did not halt: {r['result']}")
            continue
        if r["cause"] != ref.cause:
            fail(f"[{v}] halt cause {r['cause']} != ISS {ref.cause}")
        got_trace = (work / f"{v}.trace").read_text().splitlines()
        d = first_trace_diff(ref_trace, got_trace)
        if d:
            fail(f"[{v}] retirement trace differs: {d}")
        got_state = (work / f"{v}.state").read_text()
        if got_state != ref_state:
            ra, rb = ref_state.splitlines(), got_state.splitlines()
            diffs = [f"ISS '{a}' vs RTL '{b}'" for a, b in zip(ra, rb) if a != b][:3]
            if len(ra) != len(rb):
                diffs.append(f"state line count {len(ra)} vs {len(rb)}")
            fail(f"[{v}] final state differs: " + "; ".join(diffs))
        if r["assert_fails"]:
            fail(f"[{v}] {len(r['assert_fails'])} assertion failure(s), first: {r['assert_fails'][0]}")

        p = r["perf"]
        if p.get("instret") != ref.instret:
            fail(f"[{v}] instret {p.get('instret')} != ISS {ref.instret}")
        if v == "single":
            exp = perfmodel.predict_single(ref)
            if p["cycles"] != exp:
                fail(f"[single] cycles {p['cycles']} != model {exp}")
            continue
        pred = perfmodel.predict(ref, prog.imem, mem_mem_fwd=(v == "pipe"))
        for k, want in pred.as_dict().items():
            key = {"stalls_loaduse": "stalls_loaduse"}.get(k, k)
            if p.get(key) != want:
                fail(f"[{v}] perf '{k}': RTL {p.get(key)} != model {want}")
        ident = p["instret"] + 4 + p["stalls_loaduse"] + p["squashed"] + \
            (1 if ref.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR) else 0)
        if p["cycles"] != ident:
            fail(f"[{v}] cycle identity violated: cycles {p['cycles']} != {ident}")
    res["mix"] = {k: v for k, v in res["variants"].get("pipe", {}).get("perf", {}).items() if k.startswith("mix_")}
    return res


# ----------------------------------------------------------------------------------
def merge_cov(results, variant):
    merged: Dict[str, int] = {}
    for r in results:
        for k, v in r["variants"].get(variant, {}).get("cov", {}).items():
            merged[k] = merged.get(k, 0) + v
    return merged


def coverage_report(results) -> int:
    pipe = merge_cov(results, "pipe")
    nomm = merge_cov(results, "nomm")
    holes = []
    for k, v in sorted(pipe.items()):
        if k in COV_ONLY_WITHOUT_MM:
            if nomm.get(k, 0) == 0:
                holes.append(f"{k} (nomm)")
        elif v == 0:
            holes.append(k)
    hit = sum(1 for k, v in pipe.items() if v > 0 or (k in COV_ONLY_WITHOUT_MM and nomm.get(k, 0) > 0))
    print(f"\nFunctional coverage: {hit}/{len(pipe)} bins hit")
    for k, v in sorted(pipe.items()):
        extra = f"   (no-MEM->MEM build: {nomm.get(k, 0)})" if k in COV_ONLY_WITHOUT_MM else ""
        mark = " " if v > 0 or (k in COV_ONLY_WITHOUT_MM and nomm.get(k, 0) > 0) else "!"
        print(f"  {mark} {k:<32}{v:>10}{extra}")
    if holes:
        print(f"\nCOVERAGE HOLES: {', '.join(holes)}")
    return len(holes)


def print_table(results):
    print(f"\n{'test':<34}{'instret':>8}{'cycles':>8}{'CPI':>7}{'ldst':>6}{'flush':>7}  status")
    print("-" * 82)
    for r in results:
        pp = r["variants"].get("pipe", {}).get("perf", {})
        if pp:
            cpi = pp["cycles"] / max(1, pp["instret"])
            flush = pp["redirects_ex"] + pp["redirects_id"]
            row = f"{r['name']:<34}{pp['instret']:>8}{pp['cycles']:>8}{cpi:>7.2f}{pp['stalls_loaduse']:>6}{flush:>7}"
        else:
            row = f"{r['name']:<34}{'-':>8}{'-':>8}{'-':>7}{'-':>6}{'-':>7}"
        print(f"{row}  {'PASS' if r['ok'] else 'FAIL'}")
        if not r["ok"]:
            for e in r["errors"]:
                print(f"      ! {e}")


def run_many(cases, work_root, jobs):
    results = []
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(run_case, n, s, work_root): n for n, s in cases}
        for f in cf.as_completed(futs):
            try:
                results.append(f.result())
            except Exception as e:  # noqa: BLE001
                n = futs[f]
                results.append({"name": n, "ok": False, "errors": [f"harness exception: {e!r}"], "variants": {}})
    results.sort(key=lambda r: r["name"])
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["directed", "random", "all", "one"])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--seeds", type=int, default=200)
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--length", type=int, default=400, help="random program length (instructions)")
    ap.add_argument("--filter", default="")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args(argv)

    for v, p in VARIANTS.items():
        if not p.exists():
            print(f"missing {p}; run 'make sims' first", file=sys.stderr)
            return 2

    t0 = time.time()
    all_results = []
    status = 0

    if args.mode == "one":
        src = Path(args.file).resolve()
        r = run_case(src.stem, src, BUILD / "one")
        print_table([r])
        print(f"artifacts: {BUILD/'one'/src.stem}")
        return 0 if r["ok"] else 1

    if args.mode in ("directed", "all"):
        files = sorted((ROOT / "tests" / "asm").glob("*.s"))
        files = [f for f in files if args.filter in f.name]
        print(f"== directed tests: {len(files)} programs")
        results = run_many([(f.stem, f) for f in files], BUILD / "directed", args.jobs)
        print_table(results)
        all_results += results

    if args.mode in ("random", "all"):
        import randgen  # noqa: E402
        rdir = BUILD / "random_src"
        rdir.mkdir(parents=True, exist_ok=True)
        cases = []
        for s in range(args.start, args.start + args.seeds):
            p = rdir / f"rand_{s:05d}.s"
            p.write_text(randgen.generate(s, args.length))
            cases.append((p.stem, p))
        print(f"\n== constrained-random: {len(cases)} programs, ~{args.length} instructions each")
        results = run_many(cases, BUILD / "random", args.jobs)
        bad = [r for r in results if not r["ok"]]
        tot_i = sum(r["variants"].get("pipe", {}).get("perf", {}).get("instret", 0) for r in results)
        tot_c = sum(r["variants"].get("pipe", {}).get("perf", {}).get("cycles", 0) for r in results)
        print(f"  {len(results)-len(bad)}/{len(results)} passed; {tot_i} instructions retired, "
              f"{tot_c} cycles (aggregate CPI {tot_c/max(1,tot_i):.3f})")
        for r in bad[:10]:
            print(f"  FAIL {r['name']}")
            for e in r["errors"]:
                print(f"      ! {e}")
            print(f"      repro: python3 tools/regress.py one build/random_src/{r['name']}.s")
        all_results += results

    n_fail = sum(1 for r in all_results if not r["ok"])
    holes = coverage_report(all_results) if all_results else 0
    asserts = sum(r["variants"].get("pipe", {}).get("assert_checks", 0) for r in all_results)
    print(f"\nSummary: {len(all_results)-n_fail}/{len(all_results)} programs passed, "
          f"{asserts} assertion evaluations, {holes} coverage holes, {time.time()-t0:.1f}s")
    if args.mode in ("directed", "all") and args.filter == "":
        status |= 1 if holes else 0
    status |= 1 if n_fail else 0
    print("REGRESSION " + ("PASSED" if status == 0 else "FAILED"))
    return status


if __name__ == "__main__":
    sys.exit(main())
