# `main.c` - Bare-Metal TPU Driver (PS side)

The program that runs on the Zynq PS (ARM Cortex-A9). It loads two matrices
into the TPU IP, runs one matmul, reads the result back, checks it against a
software computation, and reports both correctness and timing over the UART.

It is derived from the Vitis "Hello World" template - the copyright header, the
UART description block, and the `init_platform()` / `cleanup_platform()`
scaffolding are kept; the body is the TPU driver.

---

## 1. Program flow

```
init_platform()
enable the global timer
build fixed matrices A and B            (compile-time constants)
time:  compute C on the CPU             -> C_cpu      (the PS reference)
time:  write W and X registers          (load the TPU)
time:  write CTRL, poll STATUS          (run the TPU)
time:  read C registers                 -> C_tpu
convert all timer ticks to nanoseconds
print A, B, C                           (UART)
compare C_tpu against C_cpu
print timing: PS vs PL
cleanup_platform()
```

Every measurement is taken *before* any printing - see section 4.

---

## 2. Register access

```c
#define TPU_BASE   XPS_FPGA_AXI_S0_BASEADDR
```

`TPU_BASE` resolves to the AXI base address the TPU IP was given in the Vivado
block design. Using the generated macro means the driver tracks the hardware
automatically - if the address is changed in Vivado, the firmware follows after
a rebuild, with no edit here.

The register offsets (`CTRL`, `STATUS`, `W`, `X`, `C`) match the IP's register
map. Access is plain memory-mapped I/O with `Xil_Out32` / `Xil_In32`. No cache
maintenance is needed: the AXI peripheral region is mapped non-cacheable by the
BSP, so writes and reads reach the IP directly.

---

## 3. Data packing

The matrices are 8x8 and row-major.

- `A` and `B` are `int8`. `pack()` combines 4 consecutive elements into one
  32-bit word for the AXI write, low byte first. Each byte is cast through
  `uint8_t` so a negative value keeps its two's-complement bit pattern instead
  of being sign-extended into the upper bytes. 16 words per matrix.
- `C` is read back as 64 `int32` words - one word is one result element.
  `Xil_In32` returns `uint32_t`; casting to `int32_t` restores the sign.

`A` and `B` are fixed compile-time matrices (the same data every run). Their
values stay inside the signed 8-bit range (-128...127); larger numbers cannot be
used as inputs because the hardware operands are 8-bit. Large values appear
naturally in `C`, which is 32-bit.

---

## 4. Timing - method and correctness

Timing uses the Cortex-A9 **global timer**, a free-running 64-bit counter that
increments at the CPU clock / 2.

```c
#define GTIMER_COUNT  0xF8F00200    /* counter, low 32 bits */
#define GTIMER_CTRL   0xF8F00208    /* control register     */
```

- The timer is **explicitly enabled** (`Xil_Out32(GTIMER_CTRL, 1)`) at startup.
  If it is left disabled the counter never moves and every measured interval
  reads as `0`.
- Timestamps are taken by reading `GTIMER_COUNT` directly. Only the low 32 bits
  are used - at this clock rate they wrap roughly every 13 s, far longer than a
  run, and `uint32_t` subtraction stays correct even across one wrap.
- Ticks are converted to nanoseconds in 64-bit arithmetic
  (`ticks * 1000000000 / COUNTS_PER_SECOND`) so there is no overflow, and
  `COUNTS_PER_SECOND` is exactly the counter's tick rate.

**Three things make the timing honest:**

1. **No printing inside a timed region.** The UART runs at 115200 baud - about
   87 us per character. A timer bracket that enclosed any `xil_printf` would
   measure the terminal, not the hardware. Every timestamp is captured first;
   all printing happens afterwards, at the end of `main()`.
2. **Clearly scoped intervals.** Four timestamps bracket the TPU operation and
   two more bracket the CPU matmul, so each reported number covers exactly one
   well-defined region.
3. **Waiting for a full run.** `done` stays set after a matmul until the next
   `start`, so polling `done` alone can fall straight through on the *previous*
   run's result. The driver first waits for `busy` to assert (the run has
   started), then for `done` (it has finished), so the `PL compute` window
   always spans one complete matmul.

### Reported numbers

| Label | What it measures |
|-------|------------------|
| `PS (CPU) compute` | the same 8x8 matmul done in C on the ARM core |
| `PL (TPU) compute` | `CTRL` write -> `busy` -> `done`: one full matmul |
| `PL (TPU) total run` | register writes + compute + result read-back |

Comparing `PS compute` against `PL compute` shows the systolic core is far
faster than the CPU at the multiply itself, while `PL total run` shows that
moving the operands over AXI4-Lite - 96 single-word transactions - dominates
the end-to-end time.

---

## 5. Console output

Over the UART (115200 baud) the program prints, in order:

- `Matrix A`, `Matrix B`, `Matrix C = A x B` - each as an 8x8 grid, tab-
  separated so columns align;
- `result OK` / `result WRONG` - `C_tpu` compared element-by-element to
  `C_cpu`;
- the three timing lines.

`C` is printed once: the TPU result. `C_cpu` exists only to verify the TPU and
is never printed.

---

## 6. Building and running

1. Build the `matmul` application against the platform exported from Vivado
   (the platform supplies `XPS_FPGA_AXI_S0_BASEADDR` and the BSP headers).
2. Program the FPGA with the bitstream.
3. Run the application; open a serial terminal at 115200 baud.
4. Expect the three matrices, a `result OK` line, and the timing report.
