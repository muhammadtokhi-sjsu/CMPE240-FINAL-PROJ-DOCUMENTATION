# `delay_line.v` - Programmable Delay Primitive

A `delay_line` carries one `WIDTH`-bit bus and delays it by `DEPTH` clock
cycles. It is the small reusable building block from which the skew buffers are
made - a single lane of staggering.

```
d_in  -->[ ff ]-->[ ff ]--> ... -->  d_out      (DEPTH flip-flops)
```

`d_out` in cycle `t` equals `d_in` from cycle `t - DEPTH`.

It is a pure delay: it does no arithmetic, so it is **not** declared `signed` -
the bits pass through unchanged whether they represent signed or unsigned
values.

---

## 1. Two cases, chosen at compile time

```verilog
generate
    if (DEPTH == 0) begin : g_passthrough
        assign d_out = d_in;
    end else begin : g_shift
        ... shift register ...
    end
endgenerate
```

- **`DEPTH == 0`** - there is nothing to delay, so `d_out` is just wired to
  `d_in`. No flip-flops, no clock, no reset. This is needed because the skew
  buffer's lane 0 has zero delay.
- **`DEPTH > 0`** - build a shift register `DEPTH` stages long.

The `generate if` decides this **when the design is built**, so a `DEPTH == 0`
instance literally contains no register hardware.

---

## 2. The shift register (`DEPTH > 0` case)

```verilog
reg [WIDTH-1:0] sr [0:DEPTH-1];
integer i;

always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < DEPTH; i = i + 1)
            sr[i] <= {WIDTH{1'b0}};
    end else begin
        sr[0] <= d_in;
        for (i = 1; i < DEPTH; i = i + 1)
            sr[i] <= sr[i-1];
    end
end

assign d_out = sr[DEPTH-1];
```

- `sr` is an array of `DEPTH` registers, each `WIDTH` bits wide.
- Every clock edge, `sr[0]` captures the new `d_in`, and every other stage
  copies its left neighbour - the data marches one stage per cycle.
- `d_out` is the last stage, `sr[DEPTH-1]`, so a value takes `DEPTH` cycles to
  cross.
- On `rst`, every stage is cleared so the line starts empty.

---

## 3. Verilog syntax reference

### `generate if` for structural choice
Unlike a normal `if` (which selects behaviour at run time), a `generate if`
selects **which hardware exists**. Its condition must be constant - here the
parameter `DEPTH`. The branch not taken is never built.

### Array of `reg` (shift register)
`reg [WIDTH-1:0] sr [0:DEPTH-1];` - the range before the name is each stage's
width; the range after the name is how many stages. `sr[k]` is one stage.

### `for` loop inside `always`
The `for` loops here are **unrolled** by the tool - with `DEPTH = 5` the loop
becomes 5 separate register-copy statements. It is just shorthand, not a
runtime loop. `integer i` is the loop counter.

### Non-blocking `<=` in the shift
All `sr[k] <= sr[k-1]` happen "simultaneously": every right-hand side is read
first (old values), then every stage updates. That is why the data shifts by
exactly one stage instead of racing through all stages in one cycle. Using `=`
here would be a bug.

### `{WIDTH{1'b0}}`
Replication - a `WIDTH`-bit zero that stays correct if `WIDTH` changes.

---

## 4. Timing summary

| `DEPTH` | Hardware | Relationship |
|---------|----------|--------------|
| 0 | plain wire | `d_out` = `d_in` (same cycle) |
| `D` | `D` flip-flops | `d_out` in cycle `t` = `d_in` from cycle `t-D` |

After reset the line outputs zeros until real data has had time to reach the
end - `DEPTH` cycles of fill.
