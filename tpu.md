# `tpu.v` - AXI4-Lite Slave Wrapper (the IP top)

`tpu` is the module that gets **packaged as the IP**. It wraps `tpu_core` in an
AXI4-Lite slave so the Zynq PS can drive it with plain memory-mapped reads and
writes - no custom glue logic.

```
        +---------------- tpu (IP) ----------------+
PS --AXI4-Lite-->  register file  -->  tpu_core  -->|--> result regs --> PS
        |   W / X / CTRL              (matmul)      |
        +-------------------------------------------+
```

---

## 1. Register map

The PS sees a small block of 32-bit registers. Base address is assigned by
Vivado when the IP is dropped into the block design; offsets below are relative
to that base.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x000` | `CTRL` | write | Write `1` to bit 0 -> start a matmul. |
| `0x004` | `STATUS` | read | bit 0 = `done`, bit 1 = `busy`. |
| `0x040`-`0x07C` | `W[0..15]` | write | Weight matrix - 16 words, 4 `int8`/word. |
| `0x080`-`0x0BC` | `X[0..15]` | write | Activation matrix - 16 words, 4 `int8`/word. |
| `0x100`-`0x1FC` | `C[0..63]` | read | Result matrix - 64 words, 1 `int32`/word. |

**Data packing.** Matrices are row-major. For `W`/`X`, element `(r,c)` sits at
bit `(r*N+c)*8`, so each 32-bit word holds 4 consecutive `int8` values (element
`4k` in the low byte). For `C`, each element is `int32`, so word `k` *is*
element `k` = `C[k/N][k%N]`.

**Usage sequence (PS side):**
1. Write all 16 `W` words and all 16 `X` words.
2. Write `1` to `CTRL`.
3. Poll `STATUS` until bit 0 (`done`) is set.
4. Read the 64 `C` words.

---

## 2. AXI4-Lite - just enough protocol

AXI4-Lite has five independent channels. Each transfer uses a **VALID/READY
handshake**: the sender raises `VALID`, the receiver raises `READY`, and the
beat happens on the clock edge where both are high.

| Channel | Signals | Carries |
|---------|---------|---------|
| AW (write addr) | `awaddr`, `awvalid`, `awready` | where to write |
| W (write data) | `wdata`, `wstrb`, `wvalid`, `wready` | the data + byte enables |
| B (write resp) | `bresp`, `bvalid`, `bready` | "write done" |
| AR (read addr) | `araddr`, `arvalid`, `arready` | where to read |
| R (read data) | `rdata`, `rresp`, `rvalid`, `rready` | the data |

This slave is **single-outstanding** (one transaction at a time) - the simplest
correct design, and plenty for register access.

---

## 3. Source with explanation

### Clock and reset

```verilog
wire clk = s_axi_aclk;
wire rst = ~s_axi_aresetn;
```

The IP runs entirely on the AXI clock. AXI reset is **active-low**
(`aresetn`); the rest of the design uses active-high `rst`, so it is inverted
once here.

### Write address/data handshake

```verilog
else if (!axi_awready && s_axi_awvalid && s_axi_wvalid &&
         (!axi_bvalid || s_axi_bready)) begin
    axi_awready <= 1'b1;
    axi_wready  <= 1'b1;
end else begin
    axi_awready <= 1'b0;
    axi_wready  <= 1'b0;
end
```

When the master has presented **both** an address and data, and no previous
write response is stuck, the slave pulses `awready`/`wready` high for one cycle.
That one cycle is the accepted write.

### Detecting the transfer

```verilog
wire write_hs = axi_awready & s_axi_awvalid & axi_wready & s_axi_wvalid;
```

`write_hs` is true on exactly the cycle a write is accepted - it is the "do the
write now" strobe. `read_hs` is the equivalent for reads.

### Write response

```verilog
if (write_hs)        axi_bvalid <= 1'b1;
else if (s_axi_bready) axi_bvalid <= 1'b0;
```

After accepting a write the slave raises `bvalid` ("done"); it drops once the
master acknowledges with `bready`. `bresp`/`rresp` are tied to `2'b00` = OKAY.

### Byte-strobe merge

```verilog
function [31:0] merge;
    ... merge[7:0] = strb[0] ? new_w[7:0] : old_w[7:0]; ...
endfunction
```

AXI carries 4 byte-enable strobes (`wstrb`). `merge` updates only the bytes
whose strobe is set, keeping the rest. This makes partial-word writes correct
(the PS normally writes full words, but a compliant slave handles both).

### Register writes

```verilog
start_pulse <= 1'b0;
if (write_hs) begin
    if (wr_idx == CTRL_IDX)        start_pulse <= s_axi_wdata[0];
    else if (... W range ...)      w_flat[...] <= merge(...);
    else if (... X range ...)      x_flat[...] <= merge(...);
end
```

`wr_idx = s_axi_awaddr[8:2]` is the word index. A write to `CTRL` produces a
**one-cycle `start_pulse`** (the default assignment forces it back to 0 the
next cycle) - that pulse is exactly what `tpu_core.start` expects. Writes to the
`W`/`X` ranges land in the flat matrix registers.

### Read mux

```verilog
always @(*) begin
    if (rd_idx == STAT_IDX) rd_data = {30'd0, core_busy, core_done};
    else if (... W ...)     rd_data = w_flat[...];
    else if (... X ...)     rd_data = x_flat[...];
    else if (... C ...)     rd_data = c_flat[...];
    else                    rd_data = 32'd0;
end
```

A combinational decode picks the right register; it is registered into
`axi_rdata` when `read_hs` fires. `STATUS` exposes the core's `busy`/`done`.

### The core

```verilog
tpu_core #(...) u_core (
    .start(start_pulse), .w_mat(w_flat), .x_mat(x_flat),
    .busy(core_busy), .done(core_done), .c_mat(c_flat)
);
```

The wrapper owns the registers; `tpu_core` does the compute. The flat register
buses connect straight to the core - this is why `tpu_core` has no internal
buffers.

---

## 4. Verilog syntax reference

### `function` with multiple inputs
`merge` is a pure combinational function - given old word, new word, and
strobes it returns the merged word. No clock, no delay.

### `always @(*)` - combinational block
The `(*)` sensitivity list means "re-evaluate whenever any input changes". Used
for the read mux: pure combinational logic, assigned with blocking `=`.

### Self-clearing pulse
`start_pulse <= 1'b0;` at the top of the block, optionally overridden by a later
`start_pulse <= s_axi_wdata[0];`. The last non-blocking assignment wins, so the
signal is high for at most one cycle - a clean software-triggered pulse.

### Active-low reset convention
AXI uses `aresetn` (asserted = 0). Inverting it once to `rst` keeps the rest of
the design on the simpler active-high convention.

### Unused ports (`awprot`, `arprot`)
AXI4-Lite defines protection bits; this slave does not use them. The ports must
still exist for the interface to be standard - leaving them unconnected is fine.

---

## 5. Packaging as an IP (Vivado)

1. With all RTL added, **Tools -> Create and Package IP -> Package your current
   project**.
2. Vivado auto-infers the AXI4-Lite slave from the `s_axi_*` port names. Confirm
   on the *Ports and Interfaces* page that the interface, its clock
   (`s_axi_aclk`), and reset (`s_axi_aresetn`) are recognised.
3. On *Addressing and Memory*, give the slave a register space (4 KB is fine).
4. Set the output to the shared `ip_repo\` folder and finish.

The result is a self-contained `tpu` IP - the only logic outside it is the
block-design wiring in the system project.
