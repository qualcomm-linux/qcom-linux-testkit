# Multi-Source STM + ETM Test

## Description
This test verifies the Coresight subsystem's ability to handle simultaneous trace data from:
1.  **STM (System Trace Macrocell)**: Software events.
2.  **ETM (Embedded Trace Macrocell)**: Instruction trace from all online CPUs.

It iterates through available sinks (e.g., `tmc_etf0`, `tmc_etr0`) and checks if valid binary data is captured.

## Dependencies
- **Library**: `Runner/utils/coresight_common.sh`
- **Kernel Config**: `CONFIG_CORESIGHT`, `CONFIG_CORESIGHT_STM`, `CONFIG_CORESIGHT_LINK_AND_SINK_TMC`.

## Execution
Run the script directly:
```bash
./run.sh
```

## Result
A result.res file is generated 
```bash
MultiSource_tmc_etf0: Pass
MultiSource_tmc_etr0: Pass
```