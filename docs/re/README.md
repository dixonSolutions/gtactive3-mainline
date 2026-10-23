# Reverse engineering notes

What we learnt from Samsung's binaries (`scripts/firmware-decompile`,
docs/FIRMWARE.md), written in our own words so drivers can be written
from it. One file per subsystem: `audio.md`, `sensorhub.md`, ...

These files are published. They hold facts, never Samsung's code:

- yes: register names and offsets, bit meanings, command and message IDs,
  message and file layouts, the order of operations and the delays,
  firmware load addresses and sizes, which file a component loads;
- no: decompiled functions, pseudo-code that follows one line by line,
  copied tables beyond a few constants, Samsung's comments or strings
  beyond identifiers.

Every fact names its source: the binary and the function or address it
was found in (`sensors.<soc>.so, ssp_send_cmd() @0x1f2c0`), a stock DT
node, or a snapshot file. Unconfirmed facts get a "?".

## Template

```
# <Subsystem>: what the stock firmware does

Sources: <binaries + firmware version>, <stock DT nodes>, <GPL kernel files>

## Hardware / firmware layout
## Interface (registers, messages, files)
## Sequences (probe, power on/off, suspend)
## Open questions
```
