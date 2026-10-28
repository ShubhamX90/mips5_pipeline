"""Native-Python golden results for the benchmark suite.

Each function re-implements the *algorithm* (not the assembly) from the benchmark's
header comment, using the same LCG and constants, so a benchmark's `$v0` can be
checked against an oracle that shares nothing with the ISS or the RTL.
"""
import zlib

M = 0xFFFFFFFF


def lcg(x):
    return (x * 1664525 + 1013904223) & M


def _stream(seed, n, fn):
    x, out = seed, []
    for _ in range(n):
        x = lcg(x)
        out.append(fn(x))
    return out


def fib_iter():
    a, b = 0, 1
    for _ in range(40):
        a, b = b, (a + b) & M
    return a


def factorial():
    tot, f = 0, 1
    for n in range(1, 21):
        f = (f * n) & M
        tot = (tot + f) & M
    return tot


def _weighted(a):
    return sum((i + 1) * v for i, v in enumerate(a)) & M


def bubble_sort():
    return _weighted(sorted(_stream(12345, 64, lambda x: (x >> 16) & 0xFFF)))


def insertion_sort():
    return _weighted(sorted(_stream(777, 64, lambda x: (x >> 12) & 0x3FF)))


def matmul():
    vals = _stream(99, 128, lambda x: (x >> 16) & 0xFF)
    A, B = vals[:64], vals[64:]
    tot = 0
    for i in range(8):
        for j in range(8):
            c = sum(A[i * 8 + k] * B[k * 8 + j] for k in range(8)) & M
            tot += c * (i * 8 + j + 1)
    return tot & M


def saxpy():
    x, y, s = [], [], 5
    for _ in range(256):
        s = lcg(s); x.append((s >> 16) & 0xFF)
        s = lcg(s); y.append((s >> 16) & 0xFF)
    return sum((3 * a + b) & M for a, b in zip(x, y)) & M


def memcpy_strlen():
    b = _stream(31337, 400, lambda x: ((x >> 16) & 0x7F) | 1)
    return (len(b) + sum(b)) & M


def gcd():
    from math import gcd as g
    s, tot = 4242, 0
    for _ in range(40):
        s = lcg(s); a = ((s >> 16) & 0x3FF) + 1
        s = lcg(s); b = ((s >> 16) & 0x3FF) + 1
        tot += g(a, b)
    return tot


def sieve():
    n = 1024
    comp = [False] * n
    for i in range(2, n):
        if not comp[i]:
            for j in range(i * i, n, i):
                comp[j] = True
    return sum(1 for i in range(2, n) if not comp[i])


def crc32():
    data = bytes(_stream(2024, 128, lambda x: (x >> 16) & 0xFF))
    return zlib.crc32(data) & M


def binary_search():
    table = {7 * i + 3 for i in range(256)}
    return sum(1 for k in _stream(8675309, 200, lambda x: (x >> 16) & 0x7FF) if k in table)


def linked_list():
    nxt = lambda i: (37 * i + 1) & 127  # noqa: E731
    cur, tot = 0, 0
    for _ in range(1024):
        cur = nxt(cur)
        tot += 3 * cur + 1
    return tot & M


def collatz():
    tot = 0
    for n in range(1, 251):
        while n != 1:
            n = 3 * n + 1 if n & 1 else n >> 1
            tot += 1
    return tot


def fib_recursive():
    f = lambda n: n if n < 2 else f(n - 1) + f(n - 2)  # noqa: E731
    return f(17)


def popcount():
    return sum(bin(w).count("1") for w in _stream(1337, 256, lambda x: x))


def mini_vm():
    code = _stream(99991, 256, lambda x: (x >> 20) & 3)
    acc, pc = 1, 0
    for _ in range(4096):
        op = code[pc]
        if op == 0: acc = (acc + 3) & M
        elif op == 1: acc ^= 0x55
        elif op == 2: acc = ((acc << 1) | (acc >> 31)) & M
        else: acc = (acc - 7) & M
        pc = (pc + 1) & 255
    return acc


GOLDEN = {n: f for n, f in globals().items()
          if callable(f) and n in ("fib_iter factorial bubble_sort insertion_sort matmul saxpy memcpy_strlen gcd "
                                   "sieve crc32 binary_search linked_list collatz fib_recursive popcount mini_vm").split()}

if __name__ == "__main__":
    for name, fn in GOLDEN.items():
        print(f"{name:<16}{fn():#010x}")
