# `tpu_core.v` - Integrated TPU Core (datapath + FSM)

`tpu_core` performs a **complete matmul by itself**. It
connects the three compute blocks and adds a state machine that sequences the
whole operation:

```
x_mat -> skew(in) -> pe_array -> skew(out) -> c_mat
              ^           ^                       ^
              +------- FSM controls timing -------+
```

The caller just supplies two plain matrices, pulses `start`, waits for `done`,
and reads the result. All the data staggering is hidden inside the core.

---

## 1. Interface

| Port | Dir | Width | Purpose |
|------|-----|-------|---------|
| `clk`, `rst` | in | 1 | Clock, synchronous reset. |
| `start` | in | 1 | One-cycle pulse - begin a matmul. |
| `w_mat` | in | `N*N*IN_W` | Weight matrix `W`, packed. |
| `x_mat` | in | `N*N*IN_W` | Activation matrix `X`, packed. |
| `busy` | out | 1 | High while a matmul is running. |
| `done` | out | 1 | High when the result is ready and valid. |
| `c_mat` | out | `N*N*ACC_W` | Result matrix `C = X * W`, packed. |

There are **no internal RAM/buffers**. `w_mat`/`x_mat`/`c_mat` are flat buses;
the AXI4-Lite wrapper (`tpu`) owns the actual registers and just wires them
here. This keeps the core purely about compute + control.

**Caller contract:** keep `w_mat` and `x_mat` stable from `start` until `done`.

### Packed-bus layout (row-major)

Element `(row, col)` of a matrix lives at:

```
matrix[(row*N + col)*ELEM_W +: ELEM_W]
```

`ELEM_W` is `IN_W` for `w_mat`/`x_mat`, `ACC_W` for `c_mat`. Elements are
two's-complement; signedness is handled inside `pe_array`, so these buses are
left plain.

---

## 2. The FSM

Three states:

| State | `busy` | `done` | Meaning |
|-------|--------|--------|---------|
| `S_IDLE` | 0 | 0 | Waiting for `start`. |
| `S_RUN` | 1 | 0 | Matmul in progress. |
| `S_DONE` | 0 | 1 | Result valid in `c_mat`. |

`start` triggers a run from **either** `S_IDLE` or `S_DONE` (so back-to-back
matmuls work). The result stays in `c_mat` and `done` stays high until the next
`start`.

### The cycle counter does the scheduling

Because a matmul has no data-dependent branching - it is the *same* sequence of
events every time - the work is driven by one counter, `cnt`, that runs `0` up
to `RUN_LAST` during `S_RUN`. Named `localparam`s mark the phase boundaries:

| `cnt` | Phase | What happens |
|-------|-------|--------------|
| `0 .. N-1` | LOAD | `w_load=1`; weight row `N-1-cnt` is fed to the array. |
| `N .. 2N-1` | STREAM | `X` row `cnt-N` is pushed into the input skew buffer. |
| `2N .. 3N-2` | DRAIN | data is flowing through the array + output skew. |
| `3N-1 .. 4N-2` | CAPTURE | `C` row `cnt-(3N-1)` is latched from the output skew. |
| `4N-2` | - | go to `S_DONE`. |

For `N = 8` a matmul takes 31 cycles end to end.

---

## 3. Source with explanation

### Weight feed - reverse row order

```verilog
assign wrow = (cnt <= LOAD_LAST) ? (LOAD_LAST - cnt) : 32'd0;
...
assign arr_w_in[gi*IN_W +: IN_W] = w_mat[(wrow*N + gi)*IN_W +: IN_W];
```

Weights shift *down* the array, so the bottom row must go in first. `wrow`
counts `N-1, N-2, ..., 0` as `cnt` counts `0, 1, ..., N-1`. The generate loop
picks row `wrow` of `w_mat` and presents it on the array's weight bus. `w_load`
is high only during `cnt 0..N-1`, so the array captures these and ignores the
bus afterwards.

### Activation feed - plain rows

```verilog
assign skew_in_din[gi*IN_W +: IN_W] =
    streaming ? x_mat[(xrow*N + gi)*IN_W +: IN_W] : {IN_W{1'b0}};
```

During STREAM, one **un-skewed** row of `X` per cycle is pushed into the input
skew buffer. The `skew` module adds the diagonal stagger - the core does not.
Outside STREAM the buffer is fed zeros.

### The three sub-modules

```verilog
skew     #(.WIDTH(IN_W),  .N(N), .DIR(0)) u_skew_in  (...);
pe_array #(.IN_W(IN_W), .ACC_W(ACC_W), .N(N)) u_array (...);
skew     #(.WIDTH(ACC_W), .N(N), .DIR(1)) u_skew_out (...);
```

Input skew (ascending delays) -> array -> output skew (descending delays). The
two `skew` instances differ only in `WIDTH` and `DIR`.

### Capturing the result

```verilog
if (capturing) begin
    for (c = 0; c < N; c = c + 1)
        c_mat[(caprow*N + c)*ACC_W +: ACC_W] <=
            skew_out_dout[c*ACC_W +: ACC_W];
end
```

After de-skew, an entire result row appears on `skew_out_dout` at once. Each
CAPTURE cycle latches one row (`caprow = cnt - CAP_FIRST`) into `c_mat`.

### State register

```verilog
case (state)
    S_IDLE: if (start) begin state <= S_RUN; cnt <= 0; end
    S_RUN:  begin
                ... capture ...
                if (cnt == RUN_LAST) state <= S_DONE;
                else                 cnt <= cnt + 1;
            end
    S_DONE: if (start) begin state <= S_RUN; cnt <= 0; end
endcase
```

Standard clocked FSM: reset goes to `S_IDLE`; `start` launches a run; `cnt`
walks through the schedule; reaching `RUN_LAST` finishes.

---

## 4. Verilog syntax reference

### `localparam` for states and constants
Named constants local to the module. Using `S_IDLE`/`S_RUN`/`S_DONE` and the
phase markers (`CAP_FIRST`, etc.) instead of raw numbers makes the FSM readable
and keeps the timing in one place. They are derived from `N`, so the core
re-times itself automatically if `N` changes.

### `case` statement (the FSM)
Selects behaviour by the value of `state`. The `default` branch is a safety net
- if `state` ever holds an unused value it returns to `S_IDLE`.

### Variable indexed part-select `[expr +: WIDTH]`
`w_mat[(wrow*N + gi)*IN_W +: IN_W]` - the **base** is a run-time expression
(`wrow` changes every cycle) while the **width** stays constant. This is how one
row is picked out of a packed matrix bus without a giant `case`. It is legal
both as a read (the weight/activation feeds) and as a write target (the `c_mat`
capture).

### Continuous `assign` with a condition
`assign ... = streaming ? ... : 0;` builds a multiplexer in combinational logic
- the activation feed is `X` data during STREAM and `0` otherwise.

### Counter-as-controller
`cnt` *is* the fine-grained state. A pure FSM with one state per cycle would
need ~30 states; a 3-state FSM plus a counter expresses the same schedule far
more compactly, and is the normal way to sequence a fixed-length pipeline.

---

## 5. End-to-end timing (N = 8)

```
cnt:  0 ........ 7 | 8 ....... 15 | 16 ... 22 | 23 ....... 30 | 31
      [  LOAD     ] [   STREAM   ] [  DRAIN  ] [  CAPTURE    ] DONE
```

`C[m][*]` (one full row) lands on the output skew at `cnt = m + 23`, i.e.
`cnt = m + 3N - 1`. The last row is captured at `cnt = 30`; `done` asserts the
cycle after. A matmul is 31 cycles; at 50 MHz that is 620 ns.
