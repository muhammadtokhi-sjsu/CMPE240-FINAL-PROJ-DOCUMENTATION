# `pe_array.v` - 8x8 Systolic Array

This module is the matmul engine: an `N`x`N` grid of `pe` instances (64 PEs
when `N = 8`). It contains **no new arithmetic** - all the math lives in `pe.v`.
`pe_array.v` only *tiles* the PE and wires each one to its neighbors.

It computes `C = X * W`, where:

```
C[m][c] = sum over k of  X[m][k] * W[k][c]
```

- `W[k][c]` is the stationary weight held in PE at row `k`, column `c`.
- `X` is streamed in; `C` streams out.

---

## 1. How the PEs are wired

Three signals flow through the grid, each in one fixed direction:

| Signal | Direction | Edge source | Edge sink |
|--------|-----------|-------------|-----------|
| activation | left -> right | `act_in` (left column) | dropped (right column) |
| partial sum | top -> bottom | `0` (top row) | `psum_out` (bottom row) |
| weight | top -> bottom | `w_in` (top row) | dropped (bottom row) |

The rules for one PE at row `r`, column `c`:

- `act_in`  = left neighbor's `act_out`; or external `act_in[r]` if `c == 0`.
- `psum_in` = upper neighbor's `psum_out`; or `0` if `r == 0`.
- `w_in`    = upper neighbor's `w_out`; or external `w_in[c]` if `r == 0`.

Because every PE follows the same three rules, the array is built by a
**generate loop** - there are no hand-written special cases.

---

## 2. Source with explanation

### Parameters

```verilog
parameter IN_W  = 8,
parameter ACC_W = 32,
parameter N     = 8
```

Same `IN_W`/`ACC_W` as the PE, plus `N` - the array is `N`x`N`.

### Ports - flattened buses

```verilog
input  wire signed [N*IN_W-1:0]  w_in,
input  wire signed [N*IN_W-1:0]  act_in,
output wire signed [N*ACC_W-1:0] psum_out
```

Verilog-2001 has no 2-D *ports*, so the `N` values on each edge are packed into
one wide bus. `w_in` carries `N` weights of `IN_W` bits = `N*IN_W` bits total.
Column `c`'s weight lives in bits `[c*IN_W +: IN_W]`. Same idea for `act_in`
(one entry per row) and `psum_out` (one result per column).

### Internal wires - 2-D net arrays

```verilog
wire signed [IN_W-1:0]  act_wire  [0:N-1][0:N-1];
wire signed [IN_W-1:0]  w_wire    [0:N-1][0:N-1];
wire signed [ACC_W-1:0] psum_wire [0:N-1][0:N-1];
```

Inside the module, 2-D arrays *are* allowed. `act_wire[r][c]` carries the
`act_out` of PE `(r,c)`; `w_wire` and `psum_wire` likewise. These are the wires
that connect each PE to its neighbors.

### Building the grid

```verilog
genvar r, c;
generate
    for (r = 0; r < N; r = r + 1) begin : row
        for (c = 0; c < N; c = c + 1) begin : col
            ...
        end
    end
endgenerate
```

A `generate` `for` loop is **structural replication done at compile time**. It is
not a runtime loop - the tool literally stamps out `N*N` copies of everything
inside, one per `(r,c)`. `genvar` is the special integer type used to index a
generate loop.

### Per-PE input selection

```verilog
if (r == 0)
    assign pe_w_in = $signed(w_in[c*IN_W +: IN_W]);
else
    assign pe_w_in = w_wire[r-1][c];
```

A `generate if` picks structure at compile time. For the top row it wires
`pe_w_in` to the external bus; for every other row it wires to the PE above.
The unused branch is **not even built**, so `w_wire[r-1][c]` with `r == 0` is
never elaborated - no out-of-range index. The same pattern handles `pe_act_in`
(left edge vs. left neighbor) and `pe_psum_in` (`0` at the top vs. PE above).

### Instantiating the PE

```verilog
pe #(.IN_W(IN_W), .ACC_W(ACC_W)) u_pe (
    .clk(clk), .rst(rst), .w_load(w_load),
    .w_in(pe_w_in), .act_in(pe_act_in), .psum_in(pe_psum_in),
    .w_out(w_wire[r][c]), .act_out(act_wire[r][c]), .psum_out(psum_wire[r][c])
);
```

One PE per `(r,c)`. Its three outputs drive this PE's slot in the wire arrays;
its three inputs come from the selection logic above. That is the whole array.

### Driving the output bus

```verilog
generate
    for (c = 0; c < N; c = c + 1) begin : out_map
        assign psum_out[c*ACC_W +: ACC_W] = psum_wire[N-1][c];
    end
endgenerate
```

The result of column `c` is the `psum_out` of the **bottom** PE, row `N-1`.
This loop packs the `N` bottom-row results into the flat `psum_out` bus.

---

## 3. Verilog syntax reference

### `generate` / `endgenerate`
Marks a region of **compile-time** structural code. A `generate for` replicates
hardware; a `generate if` chooses hardware. Both must use constants
(parameters, `genvar`s) in their conditions.

### `genvar`
A loop variable for generate loops. It exists only at elaboration time and ends
up as a constant inside each generated copy - `r` and `c` are fixed numbers in
every stamped-out PE.

### Named blocks `begin : row`
The `: name` labels a generate block. Labels give every generated instance a
unique hierarchical path (e.g. `row[3].col[5].u_pe`), which you need to find
signals in the simulator's waveform/scope view.

### Indexed part-select `[base +: width]`
`w_in[c*IN_W +: IN_W]` means "starting at bit `c*IN_W`, take `IN_W` bits going
up". The width must be constant; the base may vary. It is the clean way to index
into a flattened bus. (`-:` exists too and counts downward.)

### Flattened bus convention
Multiple logical values are concatenated into one wide vector because ports
cannot be 2-D. Entry `i` occupies bits `[i*W +: W]`. The testbench packs/unpacks
with the same formula, so both sides agree.

### `$signed(...)`
A part-select like `w_in[c*IN_W +: IN_W]` is **unsigned** even when `w_in` is
declared `signed` - slicing drops signedness. `$signed()` reinterprets those
bits as two's-complement so the PE receives a correctly-signed value. Forgetting
it is a classic bug that only shows up on negative numbers.

### 2-D net arrays
`wire [IN_W-1:0] act_wire [0:N-1][0:N-1];` - the `[IN_W-1:0]` before the name is
the width of each wire; the `[0:N-1][0:N-1]` after the name makes a grid of
them. Legal for internal signals, not for ports.

---

## 4. Timing - latency through the array

This array has **no input skew logic** - it expects data to arrive already
staggered. The `skew` module produces that staggering in hardware.

Each PE adds one cycle of delay. With weights loaded in cycles `0 .. N-1` and
the (pre-skewed) activations streamed starting at cycle `N`, result `C[m][c]`
appears on `psum_out[c]` after the clock edge of cycle:

```
n = m + c + (2N - 1)
```

The constant `2N-1` is `N` weight-load cycles plus the `N-1` cycles it takes for
the bottom array row to be reached - column `N-1` of `X` is the last to arrive.
The `+ m` is the input row: row `m` is streamed `m` cycles after row 0. The
`+ c` is travel right: a result emerges from column `c` one cycle later than
from column `c-1`.

For `N = 8`: the first result `C[0][0]` lands at cycle 15, the last `C[7][7]`
at cycle 29. The testbench derives expected results from this exact formula.
The reasoning behind the staggering is explained in `pe_array_tb.md`.
