--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)

local controller = {}
local currentFov = config.feedFov.defaultFov
local targetFov = currentFov

local function clamp(value: number): number
    return math.clamp(value, config.feedFov.minimumFov, config.feedFov.maximumFov)
end

function controller:Update(dt: number): number
    local blend = 1 - math.exp(-config.feedFov.transitionSpeed * dt)
    currentFov += (targetFov - currentFov) * blend
    return currentFov
end

function controller:SetTarget(value: number)
    targetFov = clamp(value)
end

function controller:GetCurrentFov(): number
    return currentFov
end

function controller:GetTargetFov(): number
    return targetFov
end

function controller:GetDefaults()
    return {
        CurrentFOV = currentFov,
        TargetFOV = targetFov,
        MinimumFOV = config.feedFov.minimumFov,
        MaximumFOV = config.feedFov.maximumFov,
        DefaultFOV = config.feedFov.defaultFov,
        FOVTransitionSpeed = config.feedFov.transitionSpeed,
    }
end

function controller:Reset()
    currentFov = config.feedFov.defaultFov
    targetFov = currentFov
end

return controller

