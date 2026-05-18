# `skew.v` - Diagonal Skew Buffer

`skew` is a bank of `N` `delay_line`s, one per lane, where each lane is delayed
by a *different* amount. That turns a square block of data into a slanted
(parallelogram) one - exactly the staggering a systolic array needs.

It is used **twice** in the TPU:

| Use | Module params | What it does |
|-----|---------------|--------------|
| input skew | `WIDTH=8`, `DIR=0` | delays activation column `i` by `i` cycles |
| output de-skew | `WIDTH=32`, `DIR=1` | delays result column `i` by `N-1-i` cycles |

One module, two instantiations - no separate code for input vs. output.

---

## 1. Why skew is needed

In `pe_array`, data marches one PE per cycle. For the dot products to line up:

- **Inputs:** column `i` of each activation row must enter the array `i` cycles
  later than column 0. Feeding a plain (unskewed) matrix would misalign every
  multiply.
- **Outputs:** result column `i` leaves the array `i` cycles after column 0, so
  to read a whole result row at once, column `i` must be held back by `N-1-i`
  cycles.

`skew` is the hardware that produces this staggering, so surrounding logic can
work with plain matrices.

---

## 2. Source with explanation

### Parameters

```verilog
parameter WIDTH = 8,   // bits per lane
parameter N     = 8,   // number of lanes
parameter DIR   = 0    // 0 = ascending delays, 1 = descending delays
```

`WIDTH` is the per-lane width - 8 for activations, 32 for results. `DIR`
chooses the delay pattern.

### Ports

```verilog
input  wire [N*WIDTH-1:0] d_in,
output wire [N*WIDTH-1:0] d_out
```

Flattened buses again: `N` lanes packed into one vector, lane `i` in bits
`[i*WIDTH +: WIDTH]`.

### Building the lanes

```verilog
genvar i;
generate
    for (i = 0; i < N; i = i + 1) begin : lane
        delay_line #(
            .WIDTH (WIDTH),
            .DEPTH ((DIR == 0) ? i : (N - 1 - i))
        ) u_dl (
            .clk   (clk),
            .rst   (rst),
            .d_in  (d_in[i*WIDTH +: WIDTH]),
            .d_out (d_out[i*WIDTH +: WIDTH])
        );
    end
endgenerate
```

A generate `for` loop stamps out `N` `delay_line`s. The key line is the
`DEPTH` override:

- `DIR == 0` (ascending): `DEPTH = i` -> lanes get delays `0,1,2,...,N-1`.
- `DIR == 1` (descending): `DEPTH = N-1-i` -> lanes get delays `N-1,...,2,1,0`.

Lane `i` reads bits `[i*WIDTH +: WIDTH]` of `d_in` and drives the matching
slice of `d_out`.

---

## 3. The two delay patterns

For `N = 8`:

```
DIR = 0  (input skew)        DIR = 1  (output de-skew)
 lane 0 : delay 0             lane 0 : delay 7
 lane 1 : delay 1             lane 1 : delay 6
 lane 2 : delay 2             lane 2 : delay 5
   ...                          ...
 lane 7 : delay 7             lane 7 : delay 0
```

Input skew adds the slant the array needs; output de-skew removes the slant the
array produced. One pre-skews, the other un-skews.

---

## 4. Verilog syntax reference

### `genvar` + generate `for`
`genvar i` indexes a compile-time replication loop. The loop body is stamped
out `N` times; `i` becomes a fixed constant inside each copy.

### Parameter value as a constant expression
`.DEPTH((DIR == 0) ? i : (N-1-i))` - a module parameter can be set to any
constant expression. `DIR`, `i`, and `N` are all constants at build time, so
each `delay_line` is built with its own fixed `DEPTH`.

### Named generate block `begin : lane`
Gives each lane a hierarchical name (`lane[3].u_dl`) for the waveform viewer.

### Connecting a part-select to a port
`.d_out(d_out[i*WIDTH +: WIDTH])` - a sub-module output can drive a *slice* of a
parent net. Each `delay_line` drives its own `WIDTH`-bit window of the wide
output bus.

### Signedness
`skew` carries signed activation/result data but never does arithmetic on it,
so the buses are left unsigned. A delay preserves the exact bit pattern; the
modules that *do* math (`pe`, `pe_array`) are the ones declared `signed`.

---

## 5. How it fits the system

```
plain X --> skew(DIR=0) --> pe_array --> skew(DIR=1) --> plain C
            (input skew)               (output de-skew)
```

`tpu_core` wires these together with an FSM controller, giving a block that
takes a plain matrix in and produces a plain matrix out - no manual staggering
anywhere.
