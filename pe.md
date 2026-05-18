# `pe.v` - Processing Element

The PE is the single repeated cell of the weight-stationary systolic array. The
8x8 array (`pe_array`) is just this one module instantiated 64 times and wired
neighbor-to-neighbor. Each PE performs one **MAC** (multiply-accumulate) per
clock cycle.

---

## 1. What the PE does

Every clock cycle, when not loading a weight, the PE computes:

```
psum_out = psum_in + (weight * act_in)
```

It also passes data to its neighbors so the array can stream:

- `act_in`  -> `act_out`  : activation moves one PE to the **right**
- `psum_in` -> `psum_out` : partial sum moves one PE **down**
- `w_in`    -> `w_out`    : weight shifts one PE **down** (only during loading)

The PE talks **only to its four neighbors** - there are no global signals. That
is what makes the array pure tiling.

---

## 2. Source with explanation

### Module header and parameters

```verilog
module pe #(
    parameter IN_W  = 8,
    parameter ACC_W = 32
) (
    ... ports ...
);
    ... body ...
endmodule
```

| Syntax | Meaning |
|--------|---------|
| `module pe ... endmodule` | Defines a hardware block named `pe`. Everything between is the block. |
| `#( parameter ... )` | The **parameter list**. Parameters are compile-time constants - they are baked in when the module is built, they are not signals. |
| `parameter IN_W = 8` | Width of the 8-bit operands (weights and activations). `= 8` is the default; an instantiating module can override it. |
| `parameter ACC_W = 32` | Width of the partial sum / accumulator path. |

Parameterizing the widths means the *same* file works if you ever change the
data sizes - you change one number instead of editing every bit range.

### Ports

```verilog
input  wire                    clk,
input  wire                    rst,
input  wire                    w_load,
input  wire signed [IN_W-1:0]  w_in,
input  wire signed [IN_W-1:0]  act_in,
input  wire signed [ACC_W-1:0] psum_in,
output wire signed [IN_W-1:0]  w_out,
output reg  signed [IN_W-1:0]  act_out,
output reg  signed [ACC_W-1:0] psum_out
```

| Port | Dir | Width | Purpose |
|------|-----|-------|---------|
| `clk` | in | 1 | Clock. All registers update on its rising edge. |
| `rst` | in | 1 | Synchronous reset, active high. Clears the registers. |
| `w_load` | in | 1 | When high, the PE captures `w_in` into its weight register. |
| `w_in` | in | 8 | Weight arriving from the PE above (or the array edge). |
| `act_in` | in | 8 | Activation arriving from the PE on the left. |
| `psum_in` | in | 32 | Partial sum arriving from the PE above. |
| `w_out` | out | 8 | This PE's stored weight, sent to the PE below. |
| `act_out` | out | 8 | `act_in` delayed one cycle, sent to the PE on the right. |
| `psum_out` | out | 32 | The MAC result, sent to the PE below. |

### Internal signals

```verilog
reg  signed [IN_W-1:0]   weight;
wire signed [2*IN_W-1:0] product;
```

- `weight` - holds the stationary weight after it is loaded.
- `product` - the multiplier output. An 8-bit x 8-bit product needs **16 bits**
  (`2*IN_W`), so its width is computed from the parameter.

### Combinational logic

```verilog
assign product = weight * act_in;
assign w_out   = weight;
```

- `product` continuously equals `weight * act_in` - it changes the instant
  either input changes (this is the multiplier).
- `w_out` continuously exposes the stored `weight` to the PE below.

### Weight register

```verilog
always @(posedge clk) begin
    if (rst)
        weight <= {IN_W{1'b0}};
    else if (w_load)
        weight <= w_in;
end
```

On each rising clock edge: if `rst`, clear the weight; else if `w_load`, capture
`w_in`. If neither is true the weight **holds its value** - that is what
"weight-stationary" means.

### MAC register

```verilog
always @(posedge clk) begin
    if (rst) begin
        act_out  <= {IN_W{1'b0}};
        psum_out <= {ACC_W{1'b0}};
    end else begin
        act_out  <= act_in;
        psum_out <= psum_in + product;
    end
end
```

On each rising edge: `act_out` becomes the previous `act_in` (one-cycle delay),
and `psum_out` becomes `psum_in + product` - the accumulate step of the MAC.

---

## 3. Verilog syntax reference

These are the language features used in `pe.v`.

### `wire` vs `reg`
- `wire` - a physical connection. It must be driven continuously, by `assign`
  or by a port of a sub-module. It cannot hold state.
- `reg` - a variable assigned **inside** an `always` block. Despite the name it
  is not always a hardware register; here, because it is assigned on
  `posedge clk`, it does synthesize to a flip-flop.

Rule of thumb: assigned in `always` -> `reg`; driven by `assign` or a submodule ->
`wire`.

### Bit ranges `[MSB:LSB]`
`[IN_W-1:0]` declares a bus. With `IN_W = 8` this is `[7:0]` - an 8-bit value,
bit 7 is the most significant. `[2*IN_W-1:0]` evaluates to `[15:0]`.

### `signed`
Marks a value as two's-complement. When **both** operands of `*` or `+` are
`signed`, Verilog does signed arithmetic and sign-extends automatically. If you
forget `signed` on even one signal, negative numbers silently compute wrong.
Every signal in this module is `signed` on purpose.

### Replication `{N{1'b0}}`
`{IN_W{1'b0}}` means "bit `0` repeated `IN_W` times" -> an 8-bit zero. It is a
width-safe way to write a constant: it stays correct if the parameter changes.

### `assign` - continuous assignment
Describes combinational logic. The left side (a `wire`) instantly tracks the
right side. Used here for the multiplier and the `w_out` pass-through.

### `always @(posedge clk)`
A block that runs on every rising edge of `clk`. Assignments inside it become
flip-flops - they describe **sequential** (clocked) logic.

### `<=` (non-blocking) vs `=` (blocking)
- `<=` non-blocking: all right-hand sides are evaluated first, then all
  registers update together. This is the correct choice inside
  `always @(posedge clk)` - it models real flip-flops updating simultaneously.
- `=` blocking: updates immediately, in order. Used for combinational logic and
  in testbench tasks, **not** for clocked registers.

### Multiplication width
In Verilog the result width of `a * b` is `width(a) + width(b)`. So an 8-bit x
8-bit multiply produces 16 bits - which is why `product` is declared
`[2*IN_W-1:0]`. Nothing is lost.

### Sign extension in the add
`psum_in` is 32-bit and `product` is 16-bit. Because both are `signed`, Verilog
sign-extends `product` to 32 bits before adding (copying its sign bit into the
upper 16 bits). A negative product stays negative. If `product` were unsigned,
the upper bits would be zero-filled and negatives would become large positives.

### Synchronous reset
The `if (rst)` is **inside** `always @(posedge clk)`, so reset only takes effect
on a clock edge. This is the reset style Xilinx FPGAs prefer.

### `use_dsp` attribute
`(* use_dsp = "yes" *)` before the module is a synthesis directive (an
attribute, not a comment). It tells the tool to implement the module's
arithmetic in DSP slices. The DSP48E1 computes `P = C + A*B` natively, so the
whole MAC - multiply, accumulate-add, and output register - packs into one DSP
slice per PE.

---

## 4. Timing - when do outputs appear?

`product` is combinational, but `psum_out` and `act_out` are registered. So if
`act_in`, `psum_in`, and `weight` are stable going into a rising edge, then
**after that edge**:

- `psum_out` holds `psum_in + weight*act_in`
- `act_out` holds the `act_in` from before the edge

Every PE adds exactly one cycle of delay. In the full array this is deliberate:
the one-cycle delay on `act_out` keeps each activation lined up with the partial
sum flowing down, so the dot products accumulate correctly. The diagonal
skew buffers exist to feed data in at the right cycle for this timing.
