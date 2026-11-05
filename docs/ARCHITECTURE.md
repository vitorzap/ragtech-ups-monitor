# Architecture

## Components

1. Ragtech UPS connected through USB CDC-ACM.
2. NUT driver and server running inside Docker.
3. QNAP V5.2 monitor implementing adaptive shutdown.
4. macOS SSH receiver for remote shutdown.
5. NoBrkMon Swift application for status monitoring.

## Data flow

Ragtech UPS
    |
    | USB /dev/ttyACM0
    v
NUT driver -> NUT server (upsd)
                    |
                    +-> QNAP V5.2 monitor
                    |       |
                    |       +-> Local QNAP shutdown
                    |       +-> Restricted SSH -> macOS shutdown
                    |
                    +-> NoBrkMon monitoring application

## Shutdown policy V5.2

Default configuration:

- Mac shutdown baseline: 30 seconds.
- QNAP shutdown baseline: 60 seconds.
- Battery reserve threshold: 50%.
- Additional delay: 15 seconds per percentage point above 50%.
- Maximum additional delay: 600 seconds.
- Battery polling interval: 5 seconds.
- Observed discharge rate can shorten deadlines.
- Existing deadlines are never extended.
- Low-battery status triggers immediate shutdown requests.
- The latest 50 operational events are retained.

The reported battery percentage is an estimate, not a
guaranteed measure of remaining UPS runtime.

The QNAP shutdown command is separately protected by
an explicit enable-real-shutdown authorization file.
