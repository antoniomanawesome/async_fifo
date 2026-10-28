# async_fifo

An asynchronous FIFO in SystemVerilog (`async_fifo.sv`). The write and read sides run on unrelated clocks, using Gray-coded pointers, 2-flop synchronizers, and a reset synchronizer per clock domain.

## Interface

| Port      | Dir | Width   | Domain | Description                              |
|-----------|-----|---------|--------|------------------------------------------|
| `wr_clk`  | in  | 1       | —      | Write clock                              |
| `rd_clk`  | in  | 1       | —      | Read clock                               |
| `rst`     | in  | 1       | any    | Active-high asynchronous reset           |
| `wr_en`   | in  | 1       | wr     | Write request                            |
| `wr_data` | in  | `WIDTH` | wr     | Data to write                            |
| `full`    | out | 1       | wr     | FIFO full, registered                    |
| `rd_en`   | in  | 1       | rd     | Read request                             |
| `rd_data` | out | `WIDTH` | rd     | Read data, registered                    |
| `empty`   | out | 1       | rd     | FIFO empty, registered                   |

### Parameters

| Parameter | Default | Description                                                                 |
|-----------|---------|-----------------------------------------------------------------------------|
| `WIDTH`   | 32      | Data width in bits                                                          |
| `DEPTH`   | 32      | Number of entries. Must be a power of 2 and at least 2; otherwise elaboration stops with an error. The FIFO holds exactly `DEPTH` words when full. |

## How it works

- **Pointers:** each side keeps a binary pointer that is `$clog2(DEPTH)+1` bits wide. The lower bits address the memory, and the extra top bit tracks wrap-around, so a full FIFO can be told apart from an empty one.
- **Gray code:** each binary pointer also has a registered Gray-coded copy (`b ^ (b >> 1)`). Only the Gray pointers cross between clock domains. A Gray value changes by one bit per increment, so a synchronizer sampling it mid-change sees either the old value or the new one, never a garbage value.
- **Synchronizers:** each Gray pointer passes through two flops in the other clock domain before it is used.
- **Flags:**
  - `full` is computed in the write domain. It compares the write pointer with the synced read pointer with the top two bits inverted, which means the same address but one lap ahead.
  - `empty` is computed in the read domain. It is set when the read pointer equals the synced write pointer.
  - Both flags are registered from the pointer's *next* value, so they have no extra cycle of latency.

## Clocks

`wr_clk` and `rd_clk` can be fully unrelated to each other, at any frequency ratio.

## Write side (`wr_clk`)

- A write happens on a `wr_clk` edge where `wr_en && !full`.
- `wr_en` while `full` is ignored: the data is dropped and the write pointer does not move.

## Read side (`rd_clk`)

- A read happens on a `rd_clk` edge where `rd_en && !empty`.
- `rd_data` is registered, so the word appears on `rd_data` right after that edge. That is **1 `rd_clk` cycle of read latency**. This is not a first-word-fall-through FIFO.
- `rd_data` holds its last value when not reading.
- `rd_en` while `empty` is ignored, and the read pointer does not move.

## Flags and latency

`full` is registered in the write domain and `empty` in the read domain.

**On its own side, a flag updates with no extra delay:**
- The write that fills the FIFO sets `full` on that same `wr_clk` edge.
- The read that drains the FIFO sets `empty` on that same `rd_clk` edge.
- So as long as the user checks the flags, overflow and underflow cannot happen.

**A change made by the other side is delayed by the crossing:**

| Event | Effect | When |
|-------|--------|------|
| Write | `empty` deasserts | 3rd `rd_clk` edge after the write (sync1 → sync2 → `empty` register) |
| Read  | `full` deasserts  | 3rd `wr_clk` edge after the read (sync1 → sync2 → `full` register) |

The first of those edges can land arbitrarily close to the event, so in practice the delay is about **2–3 periods of the receiving clock**.

**The flags are pessimistic.** `full` or `empty` can stay set for a few cycles after space or data is actually available, but they are never cleared early. This is the normal, safe trade-off for an async FIFO.

## Reset (and reset domain crossing)

- `rst` is active high and asynchronous, and can come from any domain.
- **Assert:** both domains go into reset immediately; no clock is needed.
- **Deassert:** each domain has its own 2-flop reset synchronizer (asynchronous assert, synchronous deassert). Each side leaves reset on the **2nd edge of its own clock** after `rst` drops, or the 3rd if `rst` drops right at an edge. The first write or read can happen on the edge after that. That clock must be running for the side to come out of reset.
- The two sides can leave reset on different cycles. That is safe because both pointers are held at 0 and the pointer synchronizers also reset to 0.
- **During reset:** `full = 0`, `empty = 1`, both pointers are held at 0, and any data in the FIFO is lost. `rd_data` is not reset: it keeps its old value (X at power-up) until the first read.
- **Enables during reset:** enables have no effect on the FIFO's state.

Because `full` is 0 during reset, a `wr_en` still writes `mem[0]`. The write pointer stays at 0, so the FIFO still reads as empty and that word is overwritten by the first real write after reset. I had to gate the writes with `!wr_rst` to fully block writes.

## Assertions

The assertions are inside `` `ifndef SYNTHESIS ``. They check that:
- A write while full does not move the write pointer, and a read while empty does not move the read pointer.
- Each Gray pointer changes by at most one bit per clock.

## Synthesis notes (Vivado)

- The pointer synchronizer and reset synchronizer flops are tagged `(* ASYNC_REG = "TRUE" *)`, so Vivado places each chain together and does not optimize them away.
- The Gray pointer crossings still need timing constraints. Use `set_max_delay -datapath_only` on each crossing, set to about one period of the faster clock. That keeps the delay difference between the pointer bits small enough that the receiving side never sees two bits change in one sample. `set_clock_groups -asynchronous` is weaker: it cuts these paths entirely, so there is no limit on that delay difference. These constraints belong in the XDC file and are not part of the RTL.
- `set_false_path` in the constraint file is necessary for the rst to rst synchronizer path so there's no violation reported.
- The memory itself is also a crossing: it's written on `wr_clk` and read into `rd_data` on `rd_clk`. That's safe by design, because a word is written at least 2 `rd_clk` cycles before the read side can see it. But Vivado still times the path from the memory to the `rd_data` flops between the two clocks, so it needs a constraint too (`set_max_delay -datapath_only` or `set_false_path`), or it will report violations.

## Notes for me!
- (* ASYNC_REG = "TRUE" *) implies that the input of the specified line is asynchronous so it has a chance to be metastable. 
Vivado places the chains close together (hopefully in same slice) and protects the flops from being optimized away (could be packed into an SRL shift register which is not a flop, retimed across the chain, or duplicate/merge the flops).
This also allows for synchronizer reporting.

- RDC (async assert, sync deassert)
Asserting an async rst is safe because it forces the flops to its reset value immediately (even if clk is stopped so the flop isn't sampling anything)
Releasing it async too is BAD!
The game of reset release is about recovery and removal, which is analogous to setup and hold. If rst is dropped right at a clk edge, some flops might rst on that edge or the next shoutout metastable again