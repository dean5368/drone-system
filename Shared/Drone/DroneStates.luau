--!strict

local DroneStates = {
    Unequipped = "Unequipped",
    HoldingDrone = "HoldingDrone",
    ThrowingDrone = "ThrowingDrone",
    DroneReleased = "DroneReleased",
    DroneDeployed = "DroneDeployed",
    EquippingRemote = "EquippingRemote",
    RemoteIdle = "RemoteIdle",
    EnteringFPV = "EnteringFPV",
    ControllingDrone = "ControllingDrone",
    ExitingDrone = "ExitingDrone",
}

local transitions = {
    Unequipped = {HoldingDrone = true},
    HoldingDrone = {ThrowingDrone = true, ExitingDrone = true},
    ThrowingDrone = {DroneReleased = true, ExitingDrone = true},
    DroneReleased = {DroneDeployed = true, ExitingDrone = true},
    DroneDeployed = {EquippingRemote = true, ExitingDrone = true},
    EquippingRemote = {RemoteIdle = true, ExitingDrone = true},
    RemoteIdle = {EnteringFPV = true, ExitingDrone = true},
    EnteringFPV = {ControllingDrone = true, ExitingDrone = true},
    ControllingDrone = {ExitingDrone = true},
    ExitingDrone = {Unequipped = true},
}

function DroneStates.CanTransition(fromState: string, toState: string): boolean
    return fromState == toState or transitions[fromState] ~= nil and transitions[fromState][toState] == true
end

return DroneStates
