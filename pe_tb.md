# `pe_tb.v` - Processing Element Testbench

A testbench is non-synthesizable Verilog: it is not turned into hardware, it
only runs in simulation. Its job is to drive the PE's inputs, observe its
outputs, and automatically report PASS/FAIL.

---

## 1. Structure of the testbench

1. Declare signals that connect to the PE.
2. Instantiate the PE as `dut` (device under test).
3. Generate a clock.
4. Define `task`s that perform reusable test actions.
5. An `initial` block runs the test sequence once and prints the result.

---

## 2. Source with explanation

### Timescale

```verilog
`timescale 1ns / 1ps
```

`` `timescale UNIT / PRECISION `` - a delay of `#5` means 5 ns; time is rounded
to 1 ps precision. It only affects simulation, not hardware.

### Local constants

```verilog
localparam IN_W  = 8;
localparam ACC_W = 32;
```

`localparam` is a constant that **cannot** be overridden from outside (unlike
`parameter`). Used here to keep the testbench widths matched to the PE.

### Connecting signals

```verilog
reg  ... clk, rst, w_load, w_in, act_in, psum_in;
wire ... w_out, act_out, psum_out;
```

- Signals the testbench **drives** are `reg` - they are written inside
  `initial`/`task` blocks and must hold their value between writes.
- Signals the testbench **reads** (the PE's outputs) are `wire` - they are
  driven by the PE.

### Instantiating the PE

```verilog
pe #(.IN_W(IN_W), .ACC_W(ACC_W)) dut (
    .clk(clk),
    ...
);
```

- `pe #(...)` overrides the parameters by name.
- `dut` is the instance name.
- `.clk(clk)` is **named port connection**: `.port_of_module(signal_here)`.
  Named connection is safer than positional - order does not matter.

### Clock generation

```verilog
initial clk = 1'b0;
always  #5 clk = ~clk;
```

- `initial clk = 1'b0;` sets the clock low once at time 0.
- `always #5 clk = ~clk;` flips the clock every 5 ns -> a 10 ns period
  (100 MHz). `~` is bitwise NOT. This `always` has no `@(...)` event - it just
  loops forever, which is legal only in a testbench.

### Tasks

```verilog
task load_weight;
    input signed [IN_W-1:0] value;
    begin
        ...
    end
endtask
```

A `task` is a reusable procedure - like a function that can contain delays and
clock waits. `input` declares an argument. Calling `load_weight(8'sd3)` runs the
body with `value = 3`. The four tasks here:

- `load_weight` - pulses `w_load` for one cycle to store a weight.
- `weight_check` - checks `w_out` equals the expected weight.
- `mac_check` - drives one activation/psum pair and checks the MAC result.
- `reset_check` - asserts `rst` and checks the registers clear.

### Timing controls inside tasks

```verilog
@(negedge clk);
act_in  = a;
psum_in = p;
@(posedge clk);
#1;
```

- `@(negedge clk)` - wait until the next **falling** edge. Inputs are changed on
  the falling edge so they are stable and settled before the rising edge that
  the PE uses.
- `@(posedge clk)` - wait for the **rising** edge; this is the edge where the PE
  registers its outputs.
- `#1` - wait 1 ns more, so the checks read the *new* registered values rather
  than racing the clock edge.

This negedge-drive / posedge-sample pattern avoids race conditions between the
testbench and the PE.

### Self-checking

```verilog
if (psum_out !== exp_psum) begin
    errors = errors + 1;
    $display("FAIL t=%0t psum_out=%0d expected=%0d", $time, psum_out, exp_psum);
end else begin
    $display("PASS t=%0t psum_out=%0d", $time, psum_out);
end
```

- `!==` - the **case-inequality** operator. Unlike `!=`, it also detects unknown
  (`x`) and high-impedance (`z`) bits, so an uninitialized output is caught as a
  failure.
- `errors` is an `integer` (a 32-bit signed counter) incremented on every
  mismatch.
- `$display(...)` - prints a line to the simulator console. It is a **system
  task** (the `$` prefix), used only in simulation.
- Format specifiers: `%0t` = simulation time, `%0d` = signed decimal. The `0`
  means "no padding spaces". `$time` returns the current simulation time.

### The test sequence

```verilog
initial begin
    errors = 0;
    rst    = 1'b1;
    ...
    @(negedge clk);
    @(negedge clk);
    rst = 1'b0;

    load_weight(8'sd3);
    weight_check(8'sd3);
    mac_check(8'sd5, 32'sd10, 32'sd25);
    ...
    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("TESTS FAILED errors=%0d", errors);
    $finish;
end
```

- `initial` runs **once**, starting at time 0.
- The block first initializes all inputs, holds `rst` high for two cycles, then
  releases it.
- It then runs the test cases, and finally prints an overall verdict.
- `$finish` ends the simulation.

---

## 3. Signed number literals

The testbench uses sized, signed literals. Format: `WIDTH ' s BASE VALUE`.

| Literal | Meaning |
|---------|---------|
| `8'sd3` | 8-bit, signed, decimal 3 |
| `-8'sd4` | negation of `8'sd4` -> -4 in 8 bits |
| `32'sd10` | 32-bit, signed, decimal 10 |
| `-32'sd42` | 32-bit signed -42 |
| `8'sh80` | 8-bit, signed, **hex** 80 = bit pattern `10000000` |

Why `8'sh80` and not `-8'sd128`? In 8-bit two's complement the most negative
value is -128, with bit pattern `10000000`. Writing `-8'sd128` is ambiguous
because `128` does not fit in 8 signed bits, so the hex form `8'sh80` is used to
state the exact bit pattern. It tests the corner case -128 x -128 = 16384.

---

## 4. What the test covers

| Test | Checks |
|------|--------|
| `load_weight` + `weight_check` | Weight is captured and exposed on `w_out`. |
| `mac_check(5, 10, 25)` | Basic MAC: 10 + 3x5 = 25. |
| `mac_check(-4, 100, 88)` | Negative activation: 100 + 3x(-4) = 88. |
| `mac_check(6, 0, -42)` | Negative weight: 0 + (-7)x6 = -42. |
| `mac_check(-3, -5, 16)` | Negative x negative + negative psum. |
| `8'sh80` cases | 8-bit corner: -128 x -128 = 16384, and 127 x 127 = 16129. |
| `reset_check` | Synchronous reset clears `psum_out` and `act_out`. |
| MAC after reset | Compute resumes correctly once `rst` is released. |

---

## 5. Running it in Vivado

1. Add `rtl/pe.v` as a **design source** and `sim/pe_tb.v` as a **simulation
   source**.
2. Flow Navigator -> **Run Simulation -> Run Behavioral Simulation**.
3. Read the Tcl console: you should see a list of `PASS` lines ending with
   `ALL TESTS PASSED`. Any `FAIL` line names the time, the actual value, and the
   expected value.
