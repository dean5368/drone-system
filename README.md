# Roblox Drone System

This portfolio sample contains the scripting layers of a Roblox drone-control system.
(youtube link)[https://youtu.be/gqc0TsG1Cvs]
## Included systems

- Client input for keyboard, gamepad, and mobile controls
- Smooth drone acceleration, deceleration, banking, climbing, and descent
- Server-authoritative drone movement and collision limits
- Remote-control joystick animation integration
- FPV camera and screen feed handling
- Drone lifecycle, deployment, cleanup, and state validation

## Roblox placement

Copy the files into the matching Roblox services:

- Client/Controllers → StarterPlayer.StarterPlayerScripts.Client.Controllers
- Shared/Drone → ReplicatedStorage.Shared.Drone
- Server/Services → ServerScriptService.Server.Services

The system also expects the matching RemoteEvent objects and drone/remote models. Those assets are intentionally not included in this portfolio export.

## Portfolio notes

The code was exported from a working Roblox project for review. Before using it in another place, update asset references, animation permissions, remote names, and project-specific dependencies.

Do not upload private client assets, third-party code, API keys, or the full game place without permission.
