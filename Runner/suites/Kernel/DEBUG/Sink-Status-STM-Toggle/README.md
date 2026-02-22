# Coresight Sink Status Test (STM Toggle)

## Overview
This test verifies the dependency behavior between Coresight Sources (STM, ETM) and Sinks (TMC-ETF, TMC-ETR). It ensures that sinks open and close correctly based on the activity of connected sources.

## Execution

The test performs two phases of validation for every available sink (`tmc_etf0`, `tmc_etr0`, etc., excluding `tmc_etf1`).

### Phase 1: Single Source (STM Only)
1.  **Setup**: Reset devices.
2.  **Enable**: Enable Sink $\to$ Enable STM Source.
    *   *Verification*: Check if Sink `enable_sink` is `1`.
3.  **Disable**: Disable STM Source.
    *   *Verification*: Check if Sink `enable_sink` drops to `0` (Release resource).

### Phase 2: Multi-Source (STM + ETM)
*Note: This phase runs only if an ETM device is detected.*
1.  **Setup**: Reset devices.
2.  **Enable**: Enable Sink $\to$ Enable STM Source $\to$ Enable ETM Source.
    *   *Verification*: Check if Sink `enable_sink` is `1`.
3.  **Partial Disable**: Disable **only** STM Source.
    *   *Verification*: Check if Sink `enable_sink` remains `1` (ETM should keep the sink active).
4.  **Cleanup**: Reset devices.

## Output
*   Console logs for each sink and phase transition.
*   `Sink-Status-STM-Toggle.res` containing the final Pass/Fail status.