# Raptor AI — Orange Pi 4 Pro

Smart-detection video surveillance system (NPU-accelerated), for the Orange Pi 4 Pro board.

## Prerequisites

| | |
|---|---|
| **Board** | Orange Pi 4 Pro |
| **OS image** | Debian 12 "Bookworm", our image version 1.08 — flash this before anything else |
| **Kernel** | the vendor BSP kernel that ships with that image (reports itself as `sun60iw2`) |
| **Memory** | at least 3.5 GB RAM |
| **Free storage** | at least 3 GB (8 GB+ recommended — event recordings grow over time) |
| **NPU** | driver and libraries already present in our image |
| **Network** | internet access (to download the installer, and later the 14-day trial license) |

Don't have our image yet, or not sure which version you have? Flash it first — installing on anything else isn't supported and the check below will stop you.

## Installation

On a freshly powered-on board, running the OS image we provide, as the `orangepi` user (no root needed): one command.

```
curl -fsSL https://raw.githubusercontent.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/main/raptor-install-check.sh | bash
```

This checks that the board is ready — OS, kernel, memory, free space, NPU, network — and tells you whether you can proceed. It makes no changes and installs nothing. The full guided installation follows once the check passes.
