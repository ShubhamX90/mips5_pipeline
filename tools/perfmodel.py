"""Analytical cycle-accurate performance model of the 5-stage pipeline.

Given only the *dynamic instruction stream* produced by the ISS it predicts the
exact cycle count and the stall / flush decomposition of the RTL.  The
regression requires the RTL's hardware counters to match this model for every
program, which cross-validates the hazard unit's timing (not just its
functional results).

Pipeline timing rules (see docs/HAZARDS.md):
  fill         4 cycles  (first instruction reaches WB in cycle 5)
  load-use     +1 per instruction whose very next dynamic successor consumes
               the loaded register (rt of a store excluded when MEM->MEM
               forwarding is on)
  taken branch / jr / jalr   +2   (EX-stage resolution, two slots squashed)
  j / jal                    +1   (ID-stage resolution, one slot squashed)
  halting fault (illegal / address error) occupies a WB slot without retiring: +1
Single-cycle core: cycles == retired instructions (+1 for a non-retiring fault).
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isa  # noqa: E402

FILL = 4


@dataclass
class Prediction:
    cycles: int
    instret: int
    stalls_loaduse: int
    redirects_ex: int
    redirects_id: int
    squashed: int
    branches: int
    branches_taken: int

    def as_dict(self):
        return self.__dict__.copy()


def predict(res, imem_words, mem_mem_fwd: bool = True) -> Prediction:
    """`res` is an iss.Result; `imem_words` the program image."""
    stream = [(r.instr, r.taken) for r in res.retired]
    nonretiring_fault = res.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR)
    if nonretiring_fault:
        idx = res.halt_pc >> 2
        word = imem_words[idx] if 0 <= idx < len(imem_words) else isa.ILLEGAL_FETCH
        stream.append((word, False))          # participates in hazards, never redirects

    stalls = rex = rid = br = brt = 0
    prev = None
    for instr, taken in stream:
        u = isa.usage(instr)
        if u is not None:
            if prev is not None and prev.is_load and prev.dest != 0:
                rt_needed = u.uses_rt and not (mem_mem_fwd and u.is_store)
                f = isa.fields(instr)
                if (u.uses_rs and f["rs"] == prev.dest) or (rt_needed and f["rt"] == prev.dest):
                    stalls += 1
            if u.is_cond_branch:
                br += 1
                if taken:
                    brt += 1
                    rex += 1
            elif u.is_jr and taken:
                rex += 1
            elif u.is_direct_jump:
                rid += 1
        prev = u
    n = res.instret
    squashed = 2 * rex + rid
    cycles = n + (1 if nonretiring_fault else 0) + FILL + stalls + squashed
    return Prediction(cycles, n, stalls, rex, rid, squashed, br, brt)


def predict_single(res) -> int:
    return res.instret + (1 if res.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR) else 0)


# =============================================================================
# Trace-driven timeline model with design-space what-ifs
# =============================================================================
@dataclass
class Config:
    """Microarchitecture knobs for the what-if analysis.  The default is the RTL."""
    forwarding: str = "full"       # 'full' (EX/MEM + MEM/WB + RF bypass) | 'none' (RF write-through only)
    branch: str = "ex"             # 'ex'   : resolve in EX, predict not-taken      (this design)
                                   # 'id'   : resolve in ID (needs operands one stage earlier)
                                   # 'btfn' : static backward-taken / forward-not-taken, target known in ID
    mem_mem_fwd: bool = True
    name: str = "baseline"


@dataclass
class Timeline:
    cycles: int
    stall_cycles: int = 0          # cycles lost to data hazards
    flush_cycles: int = 0          # cycles lost to control hazards
    ex_flush_events: int = 0
    id_flush_events: int = 0


def timeline(res, imem_words, cfg: Config = Config()) -> Timeline:
    """Issue-time recurrence.  t[i] is the cycle instruction i occupies EX.

    Constraints (baseline = this RTL):
        t[i] >= t[i-1] + 1                       in-order, one per cycle
        t[c] >= t[p] + lat(p)                    RAW, lat = 1 (ALU), 2 (load) with full forwarding,
                                                 3 for everything without forwarding
        t[next] >= t[b] + 3 / 2                  taken EX-resolved branch / ID-resolved jump
    Total cycles = t[last] + 2 (the last instruction still needs MEM and WB).
    """
    stream = [(r.pc, r.instr, r.taken) for r in res.retired]
    if res.cause in (isa.EXC_ILLEGAL, isa.EXC_ADDR):
        idx = res.halt_pc >> 2             # the non-retiring faulting instruction still occupies
        word = imem_words[idx] if 0 <= idx < len(imem_words) else isa.ILLEGAL_FETCH   # a slot and obeys hazards
        stream.append((res.halt_pc, word, False))
    t_prev = 2                                # so the first instruction lands in cycle 3
    ready = {}                                # reg -> (producer t, is_load)
    next_min = 0                              # redirect constraint on the next instruction
    base = stalls = flushes = rex = rid = 0
    for pc, instr, taken in stream:
        u = isa.usage(instr)
        t = max(t_prev + 1, next_min)
        if u is None:                          # illegal word: occupies a slot, touches nothing
            stalls_here = 0
            next_min = 0
            t_prev = t
            continue
        f = isa.fields(instr)
        floor_t = t
        need = []
        if u.uses_rs:
            need.append(f["rs"])
        if u.uses_rt and not (cfg.mem_mem_fwd and u.is_store):
            need.append(f["rt"])
        for r in need:
            if r == 0 or r not in ready:
                continue
            tp, is_load = ready[r]
            if cfg.forwarding == "none":
                lat = 3
            else:
                lat = 2 if is_load else 1
            if cfg.branch == "id" and (u.is_cond_branch):
                lat += 1                       # operands are needed one stage earlier
            t = max(t, tp + lat)
        stalls += t - floor_t
        # branch / jump penalties for the *next* instruction
        next_min = 0
        if u.is_cond_branch:
            backward = isa.sext(f["imm"], 16) < 0
            if cfg.branch == "ex":
                pen = 3 if taken else 0
            elif cfg.branch == "id":
                pen = 2 if taken else 0
            else:  # btfn
                if backward:
                    pen = 2 if taken else 3
                else:
                    pen = 3 if taken else 0
            if pen:
                next_min = t + pen
                flushes += pen - 1
                rex += 1
        elif u.is_jr and taken:
            next_min = t + 3
            flushes += 2
            rex += 1
        elif u.is_direct_jump:
            next_min = t + 2
            flushes += 1
            rid += 1
        if u.dest:
            ready[u.dest] = (t, u.is_load)
        t_prev = t
    cycles = t_prev + 2 if stream else 0
    return Timeline(cycles, stalls, flushes, rex, rid)
