# `pe_array_tb.v` - Systolic Array Testbench

This testbench feeds a full 8x8 matmul through `pe_array`, then checks every one
of the 64 results against a plain software reference computed inside the
testbench itself.

---

## 1. The challenge: a raw array needs *staggered* data

A systolic array does not accept a matrix "all at once". Data marches through it
one PE per cycle, so each input must arrive at the exact cycle its PE is ready.
Two things must be arranged by hand for this standalone test (the `skew`
module produces them in hardware):

1. **Weights** must be shifted in, bottom row first.
2. **Activations** must enter on a **diagonal skew** - each row delayed one more
   cycle than the row above it.

If you fed a clean, unstaggered matrix, the multiplies and the accumulating
partial sums would not line up and the results would be garbage. So the
testbench deliberately pre-skews everything.

---

## 2. Weight loading - reverse row order

Weights shift **downward** through each column. The first weight pushed in ends
up at the bottom PE; the last ends up at the top. So to land `W[r][c]` in PE
`(r,c)`, the column must be fed bottom-row-first:

```
load cycle 0 : W[N-1][c]
load cycle 1 : W[N-2][c]
...
load cycle N-1 : W[0][c]
```

`drive_load(cyc)` does exactly this: `w_in` column `j` is set to `W[N-1-cyc][j]`.
After `N` load cycles every PE holds its correct weight.

---

## 3. Activation skew - the key idea

Activation `X[m][k]` is the element of input row `m`, contraction index `k`.
The contraction index `k` selects the array row that holds `W[k][*]`, so
`X[m][k]` must enter array row `k`. It enters at:

```
cycle = N + m + k
        ^   ^   ^
        |   |   column k of X is delayed k extra cycles  (the diagonal skew)
        |   input row m starts one cycle after row m-1
        weights take N cycles to load first
```

`drive_stream(cyc)` implements this. At stream cycle `cyc`, for each lane `j` it
computes `idx = (cyc - N) - j` and feeds `act_in[j] = X[idx][j]` when `idx` is a
valid row, otherwise `0`. That `- j` is the diagonal skew: lane `j` (column `j`
of `X`) lags lane 0 by `j` cycles.

Picture the activations entering the left edge - they form a parallelogram, not
a rectangle. Each lane carries one column of `X`, and lane `j` starts `j` cycles
after lane 0:

```
            cycle -->
lane 0:  X00  X10  X20  ...
lane 1:    .  X01  X11  X21  ...
lane 2:    .    .  X02  X12  X22  ...
```

That slant is what keeps each multiply aligned with the right partial sum.

---

## 4. When results come out

Result `C[m][c]` appears on `psum_out[c]` after the clock edge of cycle:

```
n = m + c + (2N - 1)
```

`2N-1` = `N` (weight load) + `(N-1)` (partial sum draining down the column).
`sample_check(p)` inverts this: at posedge `p` it computes `m = p - (2N-1) - cc`
for each column `cc`, and if `m` is a valid row it compares that output.

---

## 5. Source with explanation

### The data matrices

```verilog
reg signed [IN_W-1:0]  X    [0:N-1][0:N-1];
reg signed [IN_W-1:0]  W    [0:N-1][0:N-1];
reg signed [ACC_W-1:0] Cref [0:N-1][0:N-1];
```

2-D `reg` arrays (memories). `X` and `W` are the test inputs; `Cref` is the
expected result.

### Filling the inputs and the reference

```verilog
X[i][j] = i + j - 7;
W[i][j] = i - j;
...
Cref[i][j] = 0;
for (k = 0; k < N; k = k + 1)
    Cref[i][j] = Cref[i][j] + X[i][k] * W[k][j];
```

`X` and `W` are filled with a pattern that spans positive **and negative**
values (so the signed datapath is exercised). `Cref` is a textbook triple-loop
matrix multiply - the trusted "golden" answer the hardware must match.

### `drive_load` - push weights in

```verilog
w_load = 1'b1;
w_in[j*IN_W +: IN_W] = W[N-1-cyc][j];
act_in[j*IN_W +: IN_W] = 0;
```

Raises `w_load`, presents one weight row (reverse order), keeps activations at
zero so nothing accumulates during loading.

### `drive_stream` - push activations in, skewed

```verilog
w_load = 1'b0;
idx = (cyc - N) - j;
if (idx >= 0 && idx < N)
    act_in[j*IN_W +: IN_W] = X[idx][j];
else
    act_in[j*IN_W +: IN_W] = 0;
```

Drops `w_load`, then for each lane `j` selects the skewed activation. Lanes
whose data has not started yet (or has finished) get `0`.

### `sample_check` - verify outputs

```verilog
m = p - (2*N - 1) - cc;
if (m >= 0 && m < N) begin
    got = psum_out[cc*ACC_W +: ACC_W];
    if (got !== Cref[m][cc]) ... FAIL
    else                     ... PASS, passes++
end
```

For posedge `p` it works out which result, if any, each column is presenting and
compares it to `Cref`. `passes` is counted so a *missing* output is caught too.

### The main loop

```verilog
for (n = 0; n < 4*N + 4; n = n + 1) begin
    @(negedge clk);
    if (n >= 1) sample_check(n - 1);
    if (n < N)  drive_load(n);
    else        drive_stream(n);
end
@(negedge clk);
sample_check(4*N + 3);
```

Each pass: wait for the falling edge, **check the previous cycle's outputs**,
then drive this cycle's inputs. Driving on the falling edge means inputs are
settled well before the rising edge the array uses. The loop runs long enough
(`4N+4` cycles) to load weights, stream all of `X`, and drain every result.

### Final verdict

```verilog
if (errors == 0 && passes == N*N)
    $display("ALL TESTS PASSED");
else
    $display("TESTS FAILED errors=%0d passes=%0d", errors, passes);
```

Both conditions matter: zero mismatches **and** all 64 outputs actually seen.

---

## 6. Verilog syntax reference

### 2-D `reg` arrays (memories)
`reg [IN_W-1:0] X [0:N-1][0:N-1];` - the range before the name is each
element's width; the ranges after the name make a 2-D array of them. Indexed
`X[i][j]`. Used for testbench data; not synthesizable as a port.

### Task-local variables
`sample_check` declares `integer m, cc;` and `reg ... got;` after its `input`
and before `begin`. These are private to each call of the task - they do not
clash with module-level names.

### `+:` part-select on a packed bus
`psum_out[cc*ACC_W +: ACC_W]` extracts result `cc` from the flat output bus -
the same packing formula `pe_array.v` uses, so the two sides line up.

### `!==` case inequality
Compares including `x`/`z` bits, so an undriven or unknown output is reported as
a failure instead of silently "matching".

### `$display` format specifiers
`%0d` prints a signed decimal with no padding; `%0t` prints simulation time.
`$display` is a simulation-only system task.

---

## 7. What the test proves

- Weights load correctly into all 64 PEs (shift-in, reverse order).
- The array performs a complete signed 8x8 x 8x8 matrix multiply.
- Negative operands and negative results are handled (signed datapath).
- All 64 elements of `C` appear, at the cycles predicted by `n = m+c+2N-1`.

If the array logic is correct you will see 64 `PASS` lines followed by
`ALL TESTS PASSED`.

---

## 8. Running it in Vivado

1. `rtl/pe.v` and `rtl/pe_array.v` are **design sources**; `pe_array` is the
   top of this simulation.
2. Add `sim/pe_array_tb.v` as a **simulation source**.
3. Flow Navigator -> **Run Simulation -> Run Behavioral Simulation**.
4. Check the Tcl console for `ALL TESTS PASSED`.
