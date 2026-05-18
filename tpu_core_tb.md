# `tpu_core_tb.v` - TPU Core Testbench

This testbench drives `tpu_core` exactly the way the PS (and the AXI wrapper)
will: hand it two **plain** matrices, pulse `start`, wait for `done`, read
`c_mat`. No skewing, no cycle-by-cycle timing - that is all inside the core now.

It runs **two** matmuls back to back to prove the core can be reused.

---

## 1. How it differs from the array testbench

`pe_array_tb` had to hand-stagger every input and know the exact cycle each
output appeared. `tpu_core_tb` does none of that - it just:

1. builds two matrices and a reference result,
2. packs them into the flat buses,
3. pulses `start` and waits on `done`,
4. unpacks `c_mat` and compares.

That contrast is the whole point of `tpu_core`: the core hides the timing.

---

## 2. Source with explanation

### `build_and_pack` - make inputs and the golden result

```verilog
X[i][j] = i + j - seed;
W[i][j] = i - j + seed;
...
Cref[i][j] = sum over k of X[i][k] * W[k][j];
...
x_mat[(i*N + j)*IN_W +: IN_W] = X[i][j];
w_mat[(i*N + j)*IN_W +: IN_W] = W[i][j];
```

- `seed` shifts the value pattern so the two runs use different data, including
  negative numbers.
- `Cref` is a plain triple-loop matrix multiply - the trusted answer.
- The last loop **packs** the 2-D arrays into the flat buses using the same
  `(i*N + j)*WIDTH` row-major formula `tpu_core` expects.

### `run_once` - one matmul

```verilog
@(negedge clk);
start = 1'b1;
@(negedge clk);
start = 1'b0;
wait (done == 1'b1);
@(negedge clk);
```

Raises `start` for exactly one clock period (one rising edge sees it), then
**`wait (done == 1'b1)`** blocks the testbench until the core signals
completion. This is how the PS will behave - kick it off, then poll/wait for
`done`. The trailing edge gives `c_mat` a moment to settle before it is read.

### `check_result` - compare against the reference

```verilog
got = c_mat[(i*N + j)*ACC_W +: ACC_W];
if (got !== Cref[i][j]) ... FAIL
else                    ... passes++
```

Unpacks every element of `c_mat` with the matching formula (`ACC_W`-wide here)
and checks it against `Cref`.

### Main sequence

```verilog
build_and_pack(7); run_once; check_result;
build_and_pack(3); run_once; check_result;
...
if (errors == 0 && passes == 2*N*N) $display("ALL TESTS PASSED");
```

Two complete matmuls with different data. The second one specifically proves
the core resets its internal state between runs (the LOAD phase reloads weights
and flushes old partial sums). `2*N*N` = 128 expected passes.

---

## 3. Verilog syntax reference

### `wait (expression)`
A level-sensitive wait: execution blocks until the expression becomes true. It
differs from `@(...)`, which waits for an *edge/event*. `wait (done == 1)` is
the natural way to say "pause until the hardware is finished" without counting
cycles. Simulation-only.

### Packing / unpacking with `[base +: WIDTH]`
The testbench and the DUT must agree on the bus layout. Both use
`(row*N + col)*WIDTH` so a 2-D matrix maps to one flat vector consistently.

### `task` with a local variable
`check_result` declares `reg signed [ACC_W-1:0] got;` - private scratch for
each call, separate from module-level names.

### One-cycle pulse
Driving `start` high on a falling edge and low on the next falling edge makes a
clean pulse that exactly one rising edge samples - the standard way to issue a
single-shot command.

---

## 4. What the test proves

- `tpu_core` computes a correct signed 8x8 x 8x8 matmul from plain matrices.
- The FSM sequences load -> stream -> drain -> capture correctly.
- `done` rises only when `c_mat` is fully valid.
- The core can run a second matmul without a reset in between.

Expect 128 `PASS` lines then `ALL TESTS PASSED`.

---

## 5. Running it in Vivado

1. Design sources: `pe.v`, `pe_array.v`, `delay_line.v`, `skew.v`, `tpu_core.v`
   (`tpu_core` is the simulation top).
2. Add `sim/tpu_core_tb.v` as a **simulation source** and set it as top.
3. Flow Navigator -> **Run Simulation -> Run Behavioral Simulation**.
4. Expect `ALL TESTS PASSED` in the Tcl console.
