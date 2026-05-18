# TPU Architecture

An 8x8 weight-stationary systolic-array matrix-multiply accelerator for the
Zynq-7000 SoC (Zybo Z7-10 board). The Processing System (PS - the ARM
Cortex-A9) generates the operand matrices; the Programmable Logic (PL - the
FPGA fabric) performs the multiply.

---

## 1. What it does

The accelerator computes one fixed-shape signed matrix multiply:

```
C = X . W

X : 8x8  int8        (activations / input)
W : 8x8  int8        (weights)
C : 8x8  int32       (result)

C[m][n] = sum over k = 0..7 of  X[m][k] * W[k][n]
```

Inputs are 8-bit two's-complement; the result is 32-bit two's-complement. A
single 8x8 x 8x8 multiply is 512 multiply-accumulate (MAC) operations.

The system has two halves:

- **PL** - the `tpu` IP: a systolic array plus a small controller, wrapped in
  an AXI4-Lite slave interface.
- **PS** - a bare-metal C program that loads the matrices into the IP, starts
  it, waits for completion, and reads the result back.

---

## 2. System block diagram

```
                      ZYNQ-7000  (Zybo Z7-10)
 +-----------------------------+        +-----------------------------------+
 |  PS  - ARM Cortex-A9        |        |  PL  - FPGA fabric                |
 |                             |  AXI4  |   +-------- tpu (IP) ----------+  |
 |  bare-metal C driver        | -Lite  |   |  AXI4-Lite slave          |  |
 |   - build X and W           |<======>|   |  register file (W/X/C)    |  |
 |   - write W, X registers    |        |   |        |                  |  |
 |   - write CTRL (start)      |        |   |    tpu_core (FSM)         |  |
 |   - poll STATUS (done)      |        |   |    skew -> pe_array -> skew|  |
 |   - read C registers        |        |   +---------------------------+  |
 +-----------------------------+        +-----------------------------------+
        runs from DDR                          one 50 MHz clock domain
```

The PS and the IP communicate only over a single AXI4-Lite link. The IP is one
clock domain driven by a PS clock (50 MHz).

---

## 3. How the TPU computes

### 3.1 Weight-stationary systolic array

The compute engine is an 8x8 grid of identical **processing elements (PEs)**.
It is *weight-stationary*: each weight `W[k][n]` is loaded once into the PE at
row `k`, column `n`, and stays there. Activations then stream through the grid;
the weights do not move during compute.

Two data streams flow through the grid while it computes:

- **activations** move **left to right**, one PE per cycle;
- **partial sums** move **top to bottom**, one PE per cycle.

A partial sum descends column `n`. At row `k` it meets activation `X[m][k]`,
adds `X[m][k] * W[k][n]`, and moves on. After descending all 8 rows it has
accumulated `sum_k X[m][k]*W[k][n] = C[m][n]` and leaves the bottom of the
column. Every PE does the same tiny operation, so the array is pure tiling -
64 copies of one cell wired to their neighbors.

### 3.2 The processing element (the MAC)

Each PE is one **multiply-accumulate** unit - one multiplier and one adder:

```
psum_out = psum_in + (weight * act_in)
```

It also forwards data to its neighbors:

- `act_in  -> act_out`  : activation passes one PE right
- `psum_in -> psum_out` : partial sum passes one PE down
- `w_in    -> w_out`    : weight passes one PE down (used only while loading)

`weight * act_in` is an 8x8 signed multiply (16-bit product); it is added to a
32-bit partial sum. The PE registers `psum_out` and `act_out`, so each PE adds
exactly one cycle of pipeline delay. There is no separate "adder stage" or
"accumulator unit" - accumulation is *spatial*: the partial sum is summed as it
flows down through the 8 PEs of a column.

### 3.3 Weight loading

Weights are shifted into the array from the top, one row per cycle, over 8
cycles. Because weights shift downward, the **bottom** row of `W` is pushed in
first and the **top** row last. After 8 load cycles every PE holds its weight.

### 3.4 Activation streaming and the diagonal skew

A systolic array cannot accept a matrix "all at once" - each value must arrive
at its PE on the exact cycle that PE is ready. The partial sum descends one
array row per cycle, so array row `k` must receive its activation one cycle
later than array row `k-1`. Array row `k` is fed column `k` of `X`, so each
column of `X` must enter one cycle later than the column before it - column `k`
delayed by `k` cycles. The activations therefore enter as a slanted
parallelogram, not a square:

```
            cycle -->
array row 0:  X00  X10  X20  ...
array row 1:    .  X01  X11  X21  ...
array row 2:    .    .  X02  X12  X22  ...
```

Array row `k` carries column `k` of `X` (`X[0][k], X[1][k], ...` over
successive cycles) and starts `k` cycles after row 0; the `.` cells are the
reset zeros present before real data has arrived.

This staggering is produced by the **skew buffer** - a bank of shift registers
where lane `k` is delayed by `k` cycles. The controller feeds it plain,
un-staggered rows of `X`, one per cycle; the skew buffer adds the column slant.
The PS never has to know about this.

### 3.5 Output de-skew and capture

Because the array is skewed on input, its results also come out skewed -
column `n`'s result appears `n` cycles after column 0's, so `7-n` cycles ahead
of the last column. A second skew buffer (delaying column `n` by `7-n` cycles)
removes this slant, so a complete result row appears on its output all at once
and is captured into the result register in a single cycle.

### 3.6 End-to-end timing

The controller is a 3-state FSM (`IDLE`, `RUN`, `DONE`) plus a cycle counter.
Because a matmul is the *same* sequence of events every time, the counter alone
drives the schedule:

```
cnt:  0 ........ 7 | 8 ....... 15 | 16 ... 22 | 23 ....... 30 | 31
      [  LOAD     ] [   STREAM   ] [  DRAIN  ] [  CAPTURE    ] DONE
```

| Phase | Cycles | Action |
|-------|--------|--------|
| LOAD | 0-7 | shift the 8 weight rows into the array |
| STREAM | 8-15 | feed the 8 rows of `X` into the input skew buffer |
| DRAIN | 16-22 | data propagates through the array and output skew |
| CAPTURE | 23-30 | latch the 8 result rows as they emerge |
| DONE | 31 | result valid, `done` asserted |

One matmul takes **31 clock cycles** - about **620 ns at 50 MHz**.

---

## 4. Module hierarchy

The RTL is fully parameterized and built bottom-up; each module has its own
detailed document in `tpu_ip/docs/`.

```
tpu                 AXI4-Lite slave wrapper - the packaged IP
+- tpu_core         datapath + FSM controller
   +- skew          input diagonal skew      (delay lane i by i)
   |  +- delay_line one configurable shift-register delay
   +- pe_array      8x8 grid of PEs
   |  +- pe         one multiply-accumulate cell
   +- skew          output de-skew           (delay lane i by N-1-i)
      +- delay_line
```

- `pe` - one MAC cell.
- `pe_array` - tiles `pe` into the 8x8 grid; contains no arithmetic of its own.
- `delay_line` / `skew` - the shift-register staggering hardware.
- `tpu_core` - wires `skew -> pe_array -> skew` and adds the FSM. Has **no
  internal memory**; it reads/writes flat operand buses.
- `tpu` - the AXI4-Lite slave: a register file plus the core. This is the
  module packaged as the IP.

---

## 5. PS to PL communication

### 5.1 AXI4-Lite register map

The IP presents a block of 32-bit registers. Offsets are relative to the base
address assigned in the block design.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x000` | `CTRL` | write | write `1` to bit 0 -> start a matmul |
| `0x004` | `STATUS` | read | bit 0 = `done`, bit 1 = `busy` |
| `0x040`-`0x07C` | `W[0..15]` | write | weight matrix, 16 words |
| `0x080`-`0x0BC` | `X[0..15]` | write | activation matrix, 16 words |
| `0x100`-`0x1FC` | `C[0..63]` | read | result matrix, 64 words |

### 5.2 The operation sequence

The PS always performs the same five steps:

1. write the 16 `W` words and the 16 `X` words;
2. write `1` to `CTRL`;
3. poll `STATUS` until bit 0 (`done`) is set;
4. read the 64 `C` words;
5. (optional) compare against a software reference.

A `CTRL` write produces a single-cycle `start` pulse inside the IP; the FSM
runs the 31-cycle schedule and raises `done`.

### 5.3 Data packing

The matrices are stored row-major and packed into 32-bit AXI words:

- `W` / `X` - elements are `int8`, so each 32-bit word carries **4 elements**,
  element `4k` in the low byte. The matrix is 64 bytes = 16 words.
- `C` - elements are `int32`, so each word **is** one element. The matrix is
  256 bytes = 64 words.

Total data moved per matmul: 64 + 64 bytes in, 256 bytes out = 384 bytes.

### 5.4 Matrices smaller than 8x8

The array is a fixed 8x8 engine: every run computes a full 8x8 by 8x8 product
on the same 31-cycle schedule. A smaller matmul is handled by **zero-padding**,
not by reconfiguring the hardware.

To compute an `M x K` by `K x N` product with `M`, `K`, `N` all 8 or less,
place the operands in the top-left of the register file and zero the rest:

- `X` - real data in rows `0..M-1`, columns `0..K-1`; every other entry `0`.
- `W` - real data in rows `0..K-1`, columns `0..N-1`; every other entry `0`.

The answer is then the top-left `M x N` block of `C`.

This is correct because of the contraction sum `C[m][n] = sum over k of
X[m][k]*W[k][n]`. For any padded index `k` (that is, `k >= K`), `X[m][k]` is
zero, so that product contributes nothing and the 8-wide dot product collapses
to the real `K`-wide one. Output rows `m >= M` and columns `n >= N` come back
as `0`, since their whole `X` row or `W` column is zero - a free sanity check.

For example, a 4x4 matmul: load the two 4x4 operands into the top-left 4x4 of
the `W` and `X` blocks, zero the other 48 entries of each, run, and read the
result from `C[0..3][0..3]`.

The padding must actually be written - stale values left in the padded region
from a previous run would corrupt the dot products.

**A smaller matmul is not a faster one.** The register file, the 31-cycle
schedule, and the 96 AXI transactions are all fixed size; the hardware never
learns the problem is smaller. A 4x4 matmul takes exactly as long as an 8x8.
The only thing that shrinks is the count of nonzero inputs.

---

## 6. Design decisions and rationale

### Weight-stationary dataflow
**Chosen** because the weights are loaded once and reused for every row of the
activation matrix, weight movement is minimal, and every PE is identical
(simple control).
*Trade-off:* a new weight matrix needs an 8-cycle reload, and the array size
fixes the contraction dimension at 8. An output-stationary scheme would keep
the partial sum in place instead but needs more operand bandwidth.
Weight-stationary is the classic, simplest choice at this scale.

### Systolic array vs. a single MAC
A single MAC unit looping over 512 operations would be tiny but take 500+
cycles. The systolic array spends 64 multipliers to finish in 31 cycles, with a
regular layout and only short wires between neighbors (good for timing).
*Trade-off:* 64 multipliers consumed, and the array must fill and drain, which
is pure overhead for very small problems.

### 8x8 array size
Sized to the demo problem and to the device: 64 PEs map to ~64 DSP slices, and
the target XC7Z010 has 80 - a comfortable fit.
*Trade-off:* only an 8x8 x 8x8 multiply is supported directly; larger matrices
would need software tiling with cross-tile accumulation.

### int8 inputs, int32 accumulator
8-bit signed inputs match typical quantized-ML data and let each multiply map
to a single DSP. Eight 16-bit products need ~19 bits to sum; 32 bits is a safe,
natural accumulator width.
*Trade-off:* inputs are limited to -128...127.

### AXI4-Lite (not full AXI4 or AXI-Stream + DMA)
With only 384 bytes per matmul, AXI4-Lite is the right tool: it is the simplest
correct bus, Vivado supplies a template, the bare-metal C is trivial
(`Xil_In32`/`Xil_Out32`), and the peripheral region is non-cacheable so there
is no cache-coherency code. The IP stays fully self-contained - no DMA engine,
no glue logic in the block design.
*Trade-off:* every word is a separate AXI transaction, so data transfer
dominates run time. Full AXI4 bursts or an AXI-Stream + DMA path would transfer
faster but add a master interface, burst logic, and cache management - far more
complexity than an 8x8 demo justifies.

### Skew buffers in hardware
The diagonal staggering is done by on-chip shift registers, so the PS sends
plain rectangular matrices and the IP is self-describing.
*Trade-off:* a small number of extra LUTs/flip-flops. The alternative -
pre-skewing the data in software - would push timing-sensitive logic into the
driver and make the register interface awkward.

### No buffers inside `tpu_core`
The AXI wrapper owns the `W`/`X`/`C` registers; `tpu_core` is pure compute and
control over flat buses. This keeps the core independently testable and
reusable, and there is exactly one copy of the operand storage.

### DSP mapping (`use_dsp` attribute)
The `pe` module carries a `use_dsp = "yes"` attribute so each MAC maps to a
DSP48E1 slice. The DSP computes `P = C + A*B` natively, so the whole MAC -
multiply, accumulate, and output register - fits in one slice, freeing fabric
LUTs/flip-flops.

### Polling, not interrupts
The PS polls the `done` bit. For a single blocking matmul this is simplest and
the spin is short (the compute is 31 cycles).
*Trade-off:* the CPU is busy while waiting. An interrupt would free it, which
would matter if the accelerator ran asynchronously alongside other work.

### Counter-driven FSM
A matmul has no data-dependent branching, so a 3-state FSM plus a cycle counter
expresses the fixed schedule far more compactly than a state-per-cycle machine.

---

## 7. Pros and cons of the design

**Strengths**

- Fully parameterized, modular RTL - one MAC cell tiled into everything above.
- Verified bottom-up: standalone testbenches for `pe`, `pe_array`, `skew`, and
  `tpu_core`, plus a full-system testbench driving the `tpu` IP over AXI4-Lite.
- Self-contained IP - drops into a block design with no hand-written glue.
- Fast core: a complete 8x8 matmul in 31 cycles.
- Simple, robust PS interface; no DMA, no cache-coherency code.
- All 64 MACs in DSP slices, leaving fabric free.

**Limitations**

- Fixed 8x8 x 8x8 shape; larger matrices need software tiling.
- AXI4-Lite moves one 32-bit word per transaction, so transfer time dominates
  the end-to-end run for small data.
- Inputs limited to 8-bit signed range.
- Weights are reloaded for every matmul (8 cycles).
- The CPU spins while polling `done`.

---

## 8. Performance

| Quantity | Value |
|----------|-------|
| Systolic core latency (design) | 31 cycles, 620 ns @ 50 MHz |
| Data moved per matmul | 384 bytes (128 in, 256 out, 96 AXI words) |
| PS software matmul (measured) | 6148 ns |
| PL compute, CTRL write to done (measured) | 263 ns |
| PL full operation: write + compute + read (measured) | 9743 ns |

The systolic core itself is fast - the matmul is 31 cycles. But the measured
*full operation* (9743 ns) is dominated by the 96 individual AXI4-Lite
transactions, not by compute: moving 384 bytes one word at a time costs far
more than the multiply. The full TPU path even runs slower than the same
matmul in software on the ARM core (6148 ns), because the register-mapped
transfer outweighs the compute it saves.

Why the bus, and not the array, sets the run time:

- **No bursts.** AXI4-Lite carries exactly one 32-bit word per transaction, so
  the 96 words become 96 independent transactions, each with its own address,
  data, and response handshake. There is no burst mode to spread that fixed
  overhead across many words.
- **Every word is a full PS-to-PL round trip.** A transaction crosses the
  processor interconnect, the general-purpose port's clock-domain crossing (the
  PS clock down to the 50 MHz fabric), the AXI interconnect in the PL, and the
  IP's own handshake - then all the way back.
- **Reads stall the CPU.** The 64 result reads are the worst part: the CPU
  issues a read and then waits, idle, until the data returns, so the full
  round-trip latency is paid 64 times in series. Writes can be posted and
  overlapped; reads cannot.
- **The fabric is slow.** At 50 MHz each PL cycle is 20 ns, and a single
  transaction spends several of them in handshakes and interconnect.

Together these turn 384 bytes into roughly 9.5 us of transfer, against a
matmul that finishes in well under 1 us. The systolic array is not the
bottleneck; the register-mapped bus feeding it is.

This is the expected result for a small accelerator on a register-mapped bus,
and it is the practical argument for burst/DMA transfer and larger problem
tiles in a production design: the compute is essentially free; feeding it is
the bottleneck.

---

## 9. Limitations and future work

- **Bandwidth** - replace the per-word AXI4-Lite transfers with an AXI4 master
  + DMA or an AXI-Stream path so the operands move in bursts.
- **Larger matrices** - add software tiling for `M`, `K`, `N` larger than 8,
  accumulating `int32` partial results across `K` tiles.
- **Weight reuse** - skip the 8-cycle reload when consecutive matmuls share the
  same weight matrix.
- **Asynchronous operation** - raise an interrupt on `done` instead of polling.
- **Scaling the array** - `N` is a parameter; a larger array is possible until
  the DSP budget is exhausted.
