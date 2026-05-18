# `skew_tb.v` - Skew Buffer Testbench

This testbench proves that every lane of a `skew` buffer is delayed by exactly
the right number of cycles, for **both** delay directions at once.

---

## 1. Test strategy

- Instantiate two `skew` buffers driven by the **same** `d_in`:
  - `dut_asc` with `DIR = 0` - expected lane delays `0,1,...,7`.
  - `dut_desc` with `DIR = 1` - expected lane delays `7,6,...,0`.
- Every cycle, feed each lane a value that is unique to that `(lane, cycle)`
  pair.
- Each cycle, check every lane of both buffers against the value that *should*
  have arrived, given that lane's delay.

Using a value that encodes both lane and cycle means a lane-swap bug or a
wrong delay is caught immediately.

---

## 2. The stimulus generator

```verilog
function [WIDTH-1:0] gen;
    input integer lane;
    input integer cyc;
    begin
        gen = lane*16 + cyc + 1;
    end
endfunction
```

`gen(lane, cyc)` produces a value that is distinct per lane (the `lane*16`
term) and per cycle (the `+ cyc`). The `+ 1` keeps it non-zero, so a real value
can never be confused with the post-reset `0`. With `lane <= 7` and `cyc < 20`
the result stays within 8 bits.

---

## 3. The checker

```verilog
task check_lane;
    input integer     lane;
    input integer     cyc;
    input integer     delay;
    input [WIDTH-1:0] got;
    reg   [WIDTH-1:0] exp;
    begin
        if (cyc >= delay)
            exp = gen(lane, cyc - delay);
        else
            exp = {WIDTH{1'b0}};
        if (got !== exp) ... FAIL
        else             ... passes++
    end
endtask
```

For a lane with delay `delay`, the output in cycle `cyc` must equal the input
fed `delay` cycles earlier - `gen(lane, cyc - delay)`. Before that much data
has arrived (`cyc < delay`) the lane is still flushing reset zeros, so the
expected value is `0`.

---

## 4. The main loop

```verilog
for (t = 0; t < NCYC; t = t + 1) begin
    @(negedge clk);
    for (i = 0; i < N; i = i + 1)
        d_in[i*WIDTH +: WIDTH] = gen(i, t);
    #1;
    for (i = 0; i < N; i = i + 1) begin
        check_lane(i, t, i,     d_out_asc [i*WIDTH +: WIDTH]);
        check_lane(i, t, N-1-i, d_out_desc[i*WIDTH +: WIDTH]);
    end
end
```

Each cycle: on the falling edge, drive a fresh value into every lane; wait `#1`
so the zero-delay (combinational) lane settles; then check all `N` lanes of
both buffers. The ascending buffer is checked with delay `i`, the descending
one with delay `N-1-i`.

`#1` matters because lane 0 of the ascending buffer (and lane `N-1` of the
descending one) is a pure wire - its output must be sampled *after* the new
`d_in` has propagated.

---

## 5. The verdict

```verilog
if (errors == 0 && passes == 2*N*NCYC)
    $display("ALL TESTS PASSED");
```

`2 * N * NCYC` checks are expected - `N` lanes x 2 buffers x `NCYC` cycles.
Requiring the exact pass count catches a check that silently never ran.

---

## 6. Verilog syntax reference

### `function`
A `function` computes a value with no time delay - no `@`, no `#`. It is used
for pure calculations (here, generating a stimulus value). Contrast with a
`task`, which *can* contain delays and clock waits.

### `task` vs `function`
- `function` - returns one value, zero simulation time. Used: `gen`.
- `task` - performs actions, may consume time, may have many in/out args.
  Used: `check_lane`.

### Two DUTs from one module
The same `skew` module is instantiated twice with different `DIR` values. This
is normal: a module is a template, each instantiation is an independent copy.

### `!==` case inequality
Catches `x`/`z` as mismatches, so an undriven lane fails loudly.

---

## 7. Running it in Vivado

1. `rtl/delay_line.v` and `rtl/skew.v` are **design sources** (`skew` is the
   simulation top, `delay_line` is its sub-module).
2. Add `sim/skew_tb.v` as a **simulation source**.
3. Flow Navigator -> **Run Simulation -> Run Behavioral Simulation**.
4. Expect `ALL TESTS PASSED` in the Tcl console.
