--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local animationData = require(ReplicatedStorage.Shared.Drone.DroneAnimations)

local controller = {}
local tracks: {[string]: AnimationTrack} = {}
local warned: {[string]: boolean} = {}

local function getAnimator(): Animator?
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end

local function stopTrack(name: string, fadeTime: number)
    local track = tracks[name]
    if not track then
        return
    end

    track:Stop(fadeTime)
    track:Destroy()
    tracks[name] = nil
end

local function prepareThrowTracks()
    local animator = getAnimator()
    if not animator then
        return
    end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track.Priority.Value >= Enum.AnimationPriority.Movement.Value then
            local animationId = track.Animation and track.Animation.AnimationId or "nil"
            print(("[DroneAnimationController] throw overlap name=%s id=%s priority=%s weight=%.2f playing=%s")
                :format(track.Name, animationId, track.Priority.Name, track.WeightCurrent, tostring(track.IsPlaying)))

            if track.Priority.Value >= Enum.AnimationPriority.Action.Value then
                track:Stop(0.08)
            end
        end
    end
end

local function loadTrack(name: string, animationInfo): AnimationTrack?
    local existing = tracks[name]
    if existing then
        if not existing.IsPlaying or existing.WeightCurrent <= 0.01 then
            existing:Play(0.05, 1, 1)
        end
        return existing
    end

    if animationInfo.kind ~= "animation" or not animationInfo.animationId then
        if not warned[name] then
            warned[name] = true
            warn(("[DroneAnimationController] %s has no animation id"):format(name))
        end
        return nil
    end

    local animator = getAnimator()
    if not animator then
        return nil
    end

    local animation = Instance.new("Animation")
    animation.Name = name
    animation.AnimationId = animationInfo.animationId

    local track = animator:LoadAnimation(animation)
    if string.sub(name, 1, 8) == "joystick" then
        track.Priority = Enum.AnimationPriority.Action2
    elseif name == "droneThrow"
        or name == "remoteEquip"
        or name == "remoteUnequip" then
        track.Priority = Enum.AnimationPriority.Action4
    elseif name == "remoteIdle" then
        track.Priority = Enum.AnimationPriority.Action
    else
        track.Priority = Enum.AnimationPriority.Idle
    end
    tracks[name] = track
    return track
end

local function playTrack(name: string, animationInfo, fadeTime: number, looped: boolean)
    local track = loadTrack(name, animationInfo)
    if not track then
        return nil
    end

    track.Looped = looped
    if not track.IsPlaying then
        track:Play(fadeTime, 1, 1)
    end
    return track
end

function controller:PlayDroneHolding()
    prepareThrowTracks()

    local track = loadTrack("droneThrow", animationData.throw)
    if not track then
        return nil
    end

    track.Looped = false
    track.Priority = Enum.AnimationPriority.Action4
    track:Play(0.1, 1, 1)
    RunService.PreAnimation:Wait()
    track.TimePosition = 0
    track:AdjustWeight(1, 0.05)
    track:AdjustSpeed(0)
    return track
end

function controller:PlayDroneThrow()
    local track = tracks.droneThrow
    if not track then
        warn("[DroneAnimationController] Drone Send track was not prepared")
        return nil
    end

    if track then
        track.Looped = false
        track.Priority = Enum.AnimationPriority.Action4
        track:AdjustWeight(1, 0.05)
        track:AdjustSpeed(1)
    end
    return track
end

function controller:PlayRemoteEquip()
    return playTrack("remoteEquip", animationData.remoteEquip, 0.1, false)
end

function controller:PlayRemoteIdle()
    stopTrack("remoteEquip", 0.1)
    return playTrack("remoteIdle", animationData.remoteIdle, 0.15, true)
end

function controller:PlayJoystick(name: string, animationInfo)
    local track = playTrack(name, animationInfo, 0.12, true)
    if track then
        track:AdjustWeight(1, 0.12)
    end
    return track
end

function controller:StopJoystick(name: string)
    local track = tracks[name]
    if not track then
        return
    end

    track:AdjustWeight(0, 0.18)
    track:Stop(0.18)
end

function controller:StopRemote()
    stopTrack("remoteEquip", 0.15)
    stopTrack("remoteIdle", 0.2)
    for name in pairs(tracks) do
        if string.sub(name, 1, 8) == "joystick" then
            stopTrack(name, 0.18)
        end
    end
end

function controller:Cleanup()
    for name in pairs(tracks) do
        stopTrack(name, 0.15)
    end
end

function controller:Init()
end

function controller:Start()
    player.CharacterAdded:Connect(function()
        self:Cleanup()
    end)
end

return controller
