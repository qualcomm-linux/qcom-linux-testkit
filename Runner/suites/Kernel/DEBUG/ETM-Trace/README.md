# ETM Trace Test

## Overview
This test validates the reliability of the ETM (Embedded Trace Macrocell) drivers by repeatedly enabling and disabling trace sources and verifying that data is successfully written to the sinks.

## Execution Logic
The test iterates through **every available sink** (excluding `tmc_etf1`) and **every available ETM source**.

For each Sink $\leftrightarrow$ Source pair, it performs `N` iterations (default: 2):
1.  **Reset**: Disable all Coresight devices.
2.  **Enable Sink**: Activate the current sink (e.g., `tmc_etr0`).
3.  **Enable Source**: Activate the current ETM (e.g., `etm0`).
4.  **Capture**: Sleep for 3 seconds to generate trace data, then dump the content of `/dev/<sink_name>` to a temporary binary file.
5.  **Verify**:
    *   Check if the captured binary file size is $\ge$ 64 bytes.
    *   Check if the source disabled correctly.

## Usage
Run the script directly or via the runner.
Optional argument: Number of iterations per device pair.
```bash
./run.sh 5
```

## Output
*   Console logs for each iteration.
*   ETM-Trace-Enable-Disable.res containing the final Pass/Fail status.