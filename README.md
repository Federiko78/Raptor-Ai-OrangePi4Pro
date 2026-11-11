# Raptor AI — Orange Pi 4 Pro

Smart-detection video surveillance system (NPU-accelerated), for the Orange Pi 4 Pro board.

## Installation

On a freshly powered-on board, running the OS image we provide, as the `orangepi` user (no root needed): one command.

```
curl -fsSL https://raw.githubusercontent.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/main/install/raptor-00-verifica.sh | bash
```

This checks that the board is ready — OS, kernel, memory, free space, NPU, network — and tells you whether you can proceed. It makes no changes and installs nothing.

## What's in this repository

The [`install/`](install/) folder contains the installation and maintenance scripts, documented in [`install/LEGGIMI.txt`](install/LEGGIMI.txt) (in Italian — the scripts' own prompts and messages are in Italian too).
