# `tpu_tb.v` - AXI4-Lite IP Testbench

This testbench acts as the Zynq PS: it talks to `tpu` over AXI4-Lite the same
way bare-metal C firmware on the PS does. It contains a small **AXI master
bus-functional model** - two tasks that perform protocol-correct reads and
writes.

---

## 1. What it does

For two different matrices, the testbench:

1. writes the 16 `W` words and 16 `X` words over AXI,
2. writes `1` to `CTRL` to start the matmul,
3. polls `STATUS` over AXI until `done` is set,
4. reads back the 64 `C` words and compares them to a reference.

This is the same sequence of register accesses any PS-side driver performs.

---

## 2. The AXI master tasks

### `axi_write(addr, data)`

```verilog
@(negedge clk);
awaddr = addr; awvalid = 1; wdata = data; wstrb = 4'b1111; wvalid = 1;
@(negedge clk);
while (!(awready && wready)) @(negedge clk);
@(negedge clk);
awvalid = 0; wvalid = 0;
while (!bvalid) @(negedge clk);
```

The master presents address + data and raises `awvalid`/`wvalid`. It holds them
until it has seen `awready`/`wready` go high (the slave accepted), then drops
them and waits for `bvalid` (the write response). `wstrb = 4'b1111` means "write
all four bytes". `bready` is tied high for the whole simulation, so the response
channel completes on its own.

### `axi_read(addr, data)`

```verilog
@(negedge clk);
araddr = addr; arvalid = 1;
@(negedge clk);
while (!arready) @(negedge clk);
@(negedge clk);
arvalid = 0;
while (!rvalid) @(negedge clk);
data = rdata;
```

Presents a read address, waits for `arready`, then waits for `rvalid` and
captures `rdata`. `rready` is tied high.

Both tasks drive signals on the **falling** edge and sample on the rising edge -
a race-free style that avoids contention with the slave's clocked logic.

---

## 3. The test flow

### `build(seed)`

Fills `X` and `W` with a seed-dependent pattern (including negatives), computes
the golden `Cref` with a triple loop, and **packs** `X`/`W` into the flat
vectors `w_packed`/`x_packed` using the row-major `(r*N+c)*8` layout.

### `do_matmul(seed)`

```verilog
build(seed);
for (k=0;k<16;k=k+1) axi_write(W_ADDR + k*4, w_packed[k*32 +: 32]);
for (k=0;k<16;k=k+1) axi_write(X_ADDR + k*4, x_packed[k*32 +: 32]);
axi_write(CTRL_ADDR, 32'h1);
while (rd[0] !== 1'b1) axi_read(STAT_ADDR, rd);
for (k=0;k<64;k=k+1) begin
    axi_read(C_ADDR + k*4, rd);
    compare rd to Cref[k/N][k%N];
end
```

This is the **whole IP-level use model**: load the matrices word by word, kick
off the run, poll for completion, read the results. `C` word `k` is one `int32`
result element, so it is compared directly to `Cref[k/N][k%N]`.

### Main block

Holds `aresetn` low for a few cycles, releases it, then runs `do_matmul` twice
with different data - proving back-to-back operation through the full AXI path.
`2*N*N` = 128 expected passes.

---

## 4. Verilog syntax reference

### Bus-functional model (BFM)
The two tasks are a tiny BFM - testbench code that *behaves like* a real bus
master without being synthesizable hardware. It lets the testbench exercise the
slave exactly as the PS would.

### `task` with `output` argument
`axi_read` has `output [31:0] data`. When the task finishes, the value is copied
back into the variable the caller passed - that is how the read result gets out.

### Tying handshake signals high
`bready` and `rready` are set once and left high. A master that is always ready
to accept responses never stalls the slave - fine for a simple testbench.

### Indexed part-select for packing
`w_packed[k*32 +: 32]` slices the flat 512-bit vector into 32-bit words for the
AXI writes - the same packing the register map documents.

### `while` polling
`while (rd[0] !== 1'b1) axi_read(STAT_ADDR, rd);` re-reads `STATUS` until `done`
is set - a standard completion poll.

---

## 5. What the test proves

- The AXI4-Lite slave handles writes (`W`, `X`, `CTRL`) and reads
  (`STATUS`, `C`) with correct handshaking.
- `CTRL` writes start the core; `STATUS` reflects `busy`/`done`.
- A full matmul works end to end through the packaged-IP interface.
- Two runs back to back succeed.

Expect 128 `PASS` lines then `ALL TESTS PASSED`.

---

## 6. Running it in Vivado

1. Design sources: all of `pe.v`, `pe_array.v`, `delay_line.v`, `skew.v`,
   `tpu_core.v`, `tpu.v` (`tpu` is the simulation top).
2. Add `sim/tpu_tb.v` as a **simulation source** and set it as top.
3. Flow Navigator -> **Run Simulation -> Run Behavioral Simulation**.
4. Expect `ALL TESTS PASSED` in the Tcl console.
