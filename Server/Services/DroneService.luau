--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack = game:GetService("StarterPack")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local states = require(ReplicatedStorage.Shared.Drone.DroneStates)

local droneService = {}

local activeDrones: {[Player]: Model} = {}
local heldDrones: {[Player]: Model} = {}
local droneConnections: {[Player]: RBXScriptConnection} = {}
local backpackConnections: {[Player]: RBXScriptConnection} = {}
local watchedBackpacks: {[Player]: Instance} = {}
local lastDeploy: {[Player]: number} = {}
local lastRemoteActivation: {[Player]: number} = {}
local sessionCounters: {[Player]: number} = {}
local deployCooldown = 0.75

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local deployEvent = remotes:WaitForChild("DroneDeploy")
local cleanupEvent = remotes:WaitForChild("DroneCleanup")
local remoteActivate = remotes:WaitForChild("RemoteActivate")
local stateEvent = remotes:WaitForChild("DroneStateChanged")

local function toolIsReady(tool: Instance, name: string): boolean
    if not tool:IsA("Tool") then
        return false
    end

    local modelName = name == "Drone" and "DroneModel" or "RemoteModel"
    local rootName = name == "Drone" and "DroneRoot" or "RemoteRoot"
    local model = tool:FindFirstChild(modelName)
    local root = model and model:FindFirstChild(rootName, true)
    local handle = tool:FindFirstChild("Handle")
    local screen = name == "Remote" and model and model:FindFirstChild("FPVScreen", true)

    return model ~= nil
        and model:IsA("Model")
        and root ~= nil
        and root:IsA("BasePart")
        and handle ~= nil
        and handle:IsA("BasePart")
        and (name ~= "Remote" or screen ~= nil)
end

local function getToolTemplate(name: string): Instance?
    return StarterPack:FindFirstChild(name) or ReplicatedStorage:FindFirstChild(name)
end

local function removeTool(player: Player, name: string)
    for _, container in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and child.Name == name then
                    child:Destroy()
                end
            end
        end
    end
end

local function giveTool(player: Player, name: string)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local template = getToolTemplate(name)

    if not backpack or not template or not toolIsReady(template, name) then
        warn("[DroneService] incomplete " .. name .. " template")
        return
    end

    local readyTool
    local containers = {backpack, player.Character}

    for _, container in ipairs(containers) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and child.Name == name then
                    if toolIsReady(child, name) and not readyTool then
                        readyTool = child
                    else
                        child:Destroy()
                    end
                end
            end
        end
    end

    if not readyTool then
        template:Clone().Parent = backpack
    end
end

local function replaceTool(player: Player, name: string)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local template = getToolTemplate(name)
    if not backpack or not template or not toolIsReady(template, name) then
        warn("[DroneService] could not replace " .. name)
        return
    end

    local character = player.Character
    for _, container in ipairs({backpack, character}) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and child.Name == name then
                    child:Destroy()
                end
            end
        end
    end

    template:Clone().Parent = backpack
end

local function setStoredTools(player: Player)
    removeTool(player, "Remote")
    giveTool(player, "Drone")
end

local function setDeployedTools(player: Player)
    removeTool(player, "Drone")
    removeTool(player, "Remote")
    giveTool(player, "Remote")
end

local function getLifecycleState(player: Player): string
    return player:GetAttribute("DroneSessionState") or states.Unequipped
end

local function transitionPlayer(
    player: Player,
    nextState: string,
    requestedSessionId: number?,
    reason: string,
    notifyClient: boolean,
    requestToken: string?
): boolean
    local previousState = getLifecycleState(player)
    local currentSessionId = player:GetAttribute("DroneSessionId")

    if not states.CanTransition(previousState, nextState) then
        warn(("[DroneLifecycle][Server] rejected transition %s -> %s for %s (%s)")
            :format(previousState, nextState, player.Name, reason))
        return false
    end

    if requestedSessionId ~= nil and currentSessionId ~= nil and requestedSessionId ~= currentSessionId then
        warn(("[DroneLifecycle][Server] rejected stale session %s for %s; active session is %s")
            :format(tostring(requestedSessionId), player.Name, tostring(currentSessionId)))
        return false
    end

    local eventSessionId = requestedSessionId or currentSessionId
    player:SetAttribute("DroneSessionState", nextState)
    if nextState == states.Unequipped then
        player:SetAttribute("DroneSessionId", nil)
        player:SetAttribute("DroneCleanupPending", false)
    elseif requestedSessionId ~= nil then
        player:SetAttribute("DroneSessionId", requestedSessionId)
    end

    if nextState == states.ExitingDrone then
        player:SetAttribute("DroneCleanupPending", true)
    end

    print(("[DroneLifecycle][Server] %s -> %s | player=%s | session=%s | %s")
        :format(previousState, nextState, player.Name, tostring(eventSessionId), reason))

    if notifyClient then
        stateEvent:FireClient(player, {
            state = nextState,
            sessionId = eventSessionId,
            requestToken = requestToken,
            reason = reason,
        })
    end

    return true
end

local function hasOwnedDroneTool(player: Player): boolean
    local source = getToolTemplate("Drone")
    if not source or not toolIsReady(source, "Drone") then
        return false
    end

    local count = 0
    local equipped = false

    for _, container in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and child.Name == "Drone" then
                    local handle = child:FindFirstChild("Handle")
                    if not handle or not handle:IsA("BasePart") then
                        return false
                    end

                    count += 1
                    equipped = equipped or child.Parent == player.Character
                end
            end
        end
    end

    return count == 1 and equipped
end

local function giveTools(player: Player)
    if activeDrones[player] and activeDrones[player].Parent then
        setDeployedTools(player)
    else
        setStoredTools(player)
        transitionPlayer(player, states.Unequipped, nil, "ToolsStored", false)
    end
end

local function watchBackpack(player: Player)
    local backpack = player:FindFirstChildOfClass("Backpack")
        or player:WaitForChild("Backpack", 5)
    if not backpack or not backpack:IsA("Backpack") then
        return
    end

    if backpackConnections[player] and watchedBackpacks[player] == backpack then
        return
    end

    local oldConnection = backpackConnections[player]
    if oldConnection then
        oldConnection:Disconnect()
    end

    watchedBackpacks[player] = backpack
    backpackConnections[player] = backpack.ChildRemoved:Connect(function(child)
        if not child:IsA("Tool") or child.Name ~= "Drone" then
            return
        end

        task.defer(function()
            if player.Parent ~= Players
                or player:GetAttribute("DroneSessionState") ~= states.Unequipped then
                return
            end

            local currentBackpack = player:FindFirstChildOfClass("Backpack")
            local character = player.Character
            if currentBackpack
                and not currentBackpack:FindFirstChild("Drone")
                and not (character and character:FindFirstChild("Drone")) then
                giveTool(player, "Drone")
            end
        end)
    end)
end

local function getFolder(): Folder
    local folder = Workspace:FindFirstChild("ActiveDrones")
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = "ActiveDrones"
    folder.Parent = Workspace
    return folder
end

local function clearHeldDrone(player: Player)
    local held = heldDrones[player]
    heldDrones[player] = nil
    if held then
        held:Destroy()
    end

    local character = player.Character
    if character then
        local leftover = character:FindFirstChild("HeldDrone")
        if leftover then
            leftover:Destroy()
        end
    end
end

local function removeDrone(player: Player, requestedSessionId: number?, cleanupToken: string?)
    local activeSessionId = player:GetAttribute("DroneSessionId")
    clearHeldDrone(player)
    if requestedSessionId ~= nil
        and (typeof(requestedSessionId) ~= "number" or requestedSessionId ~= activeSessionId) then
        warn(("[DroneLifecycle][Server] ignored stale cleanup for %s: requested=%s active=%s")
            :format(player.Name, tostring(requestedSessionId), tostring(activeSessionId)))
        return
    end

    local hadSession = activeDrones[player] ~= nil
        or getLifecycleState(player) ~= states.Unequipped
        or activeSessionId ~= nil
    local sessionId = activeSessionId

    local connection = droneConnections[player]
    if connection then
        connection:Disconnect()
        droneConnections[player] = nil
    end

    local drone = activeDrones[player]
    activeDrones[player] = nil
    if drone then
        drone:Destroy()
    end

    local folder = Workspace:FindFirstChild("ActiveDrones")
    local leftover = folder and folder:FindFirstChild(player.Name .. "_Drone")
    if leftover then
        leftover:Destroy()
    end

    lastDeploy[player] = nil
    lastRemoteActivation[player] = nil

    if hadSession then
        if getLifecycleState(player) ~= states.ExitingDrone then
            transitionPlayer(player, states.ExitingDrone, sessionId, "ServerCleanup", true, cleanupToken)
        end
        setStoredTools(player)
        transitionPlayer(player, states.Unequipped, sessionId, "ServerCleanupComplete", true, cleanupToken)
    else
        setStoredTools(player)
        transitionPlayer(player, states.Unequipped, nil, "ToolsStored", false)
    end
end

local function watchDrone(player: Player, drone: Model)
    local oldConnection = droneConnections[player]
    if oldConnection then
        oldConnection:Disconnect()
    end

    droneConnections[player] = drone.Destroying:Connect(function()
        if activeDrones[player] ~= drone then
            return
        end

        activeDrones[player] = nil
        droneConnections[player] = nil
        lastDeploy[player] = nil
        lastRemoteActivation[player] = nil

        local sessionId = player:GetAttribute("DroneSessionId") or sessionCounters[player]
        if getLifecycleState(player) ~= states.ExitingDrone then
            transitionPlayer(player, states.ExitingDrone, sessionId, "DroneDestroyed", true)
        end
        setStoredTools(player)
        transitionPlayer(player, states.Unequipped, sessionId, "DroneDestroyedComplete", true)
    end)
end

local function getSource(): Model?
    local source = Workspace:FindFirstChild("Drone")

    if not source or not source:IsA("Model") then
        local tool = StarterPack:FindFirstChild("Drone")
        source = tool and tool:FindFirstChild("DroneModel")
    end

    if not source or not source:IsA("Model") then
        return nil
    end

    local root = source.PrimaryPart or source:FindFirstChild("DroneRoot", true)
    if not root or not root:IsA("BasePart") then
        return nil
    end

    local hasPart = false
    for _, object in ipairs(source:GetDescendants()) do
        if object:IsA("BasePart") then
            hasPart = true
            break
        end
    end

    if not hasPart then
        return nil
    end

    source.PrimaryPart = root
    return source
end

local function createHeldDrone(player: Player): Model?
    clearHeldDrone(player)

    local character = player.Character
    local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
    local source = getSource()
    if not character or not humanoidRootPart or not humanoidRootPart:IsA("BasePart") or not source then
        return nil
    end

    local model = source:Clone()
    model.Name = "HeldDrone"
    model:SetAttribute("ServerHeld", true)

    local root = model.PrimaryPart or model:FindFirstChild("DroneRoot", true)
    if not root or not root:IsA("BasePart") then
        model:Destroy()
        return nil
    end
    model.PrimaryPart = root

    local bodyAttach = model:FindFirstChild("BodyAttach", true)
    if not bodyAttach then
        bodyAttach = Instance.new("Part")
        bodyAttach.Name = "BodyAttach"
        bodyAttach.Size = Vector3.new(1, 1, 1)
        bodyAttach.Transparency = 1
        bodyAttach.Parent = model
    end
    if not bodyAttach:IsA("BasePart") then
        model:Destroy()
        return nil
    end

    bodyAttach.CFrame = root.CFrame
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") then
            object.Anchored = false
            object.Massless = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
        end
    end

    model.Parent = character
    model:PivotTo(humanoidRootPart.CFrame)
    root.CFrame = root.CFrame * config.DroneModelOrientationOffset

    local bodyWeld = Instance.new("WeldConstraint")
    bodyWeld.Name = "HeldDroneBodyAttachWeld"
    bodyWeld.Part0 = root
    bodyWeld.Part1 = bodyAttach
    bodyWeld.Parent = root

    local motor = Instance.new("Motor6D")
    motor.Name = "Motor6D"
    motor.Part0 = humanoidRootPart
    motor.Part1 = bodyAttach
    motor.C0 = config.DroneHoldOffset
    motor.C1 = CFrame.identity
    motor.Parent = model

    heldDrones[player] = model
    model.Destroying:Connect(function()
        if heldDrones[player] == model then
            heldDrones[player] = nil
        end
    end)
    return model
end

local function isValidRelease(player: Player, releaseCFrame: CFrame): boolean
    if player.Parent ~= Players or typeof(releaseCFrame) ~= "CFrame" then
        return false
    end

    local position = releaseCFrame.Position
    local look = releaseCFrame.LookVector
    if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z
        or look.X ~= look.X or look.Y ~= look.Y or look.Z ~= look.Z
        or look.Magnitude < 0.9 then
        return false
    end

    if position.Y <= Workspace.FallenPartsDestroyHeight + 2 then
        return false
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root:IsA("BasePart") then
        return false
    end

    return (root.Position - position).Magnitude <= 20
end

local function getFpvCameraCFrame(drone: Model, root: BasePart): CFrame
    local forward = root.CFrame.LookVector
    local up = root.CFrame.UpVector
    local frontExtent = 0

    for _, object in ipairs(drone:GetDescendants()) do
        if object:IsA("BasePart") then
            local offset = object.Position - root.Position
            local extent = math.abs(object.CFrame.RightVector:Dot(forward)) * object.Size.X * 0.5
                + math.abs(object.CFrame.UpVector:Dot(forward)) * object.Size.Y * 0.5
                + math.abs(object.CFrame.LookVector:Dot(forward)) * object.Size.Z * 0.5
            frontExtent = math.max(frontExtent, offset:Dot(forward) + extent)
        end
    end

    local position = root.Position + forward * (frontExtent + 0.5) + up * 0.15
    return CFrame.lookAt(position, position + forward, up)
end

local function configureDrone(drone: Model)
    local root = drone.PrimaryPart
    drone:SetAttribute("ControlsEnabled", false)

    if root and not drone:FindFirstChild("FPVCamera", true) then
        local camera = Instance.new("Camera")
        camera.Name = "FPVCamera"
        camera.CFrame = getFpvCameraCFrame(drone, root)
        camera.FieldOfView = config.camera.fpvFov
        camera.Parent = drone
        drone:SetAttribute("FPVCameraCFrame", camera.CFrame)
        drone:SetAttribute("FPVCameraFov", camera.FieldOfView)
    end

    for _, object in ipairs(drone:GetDescendants()) do
        if object:IsA("BasePart") then
            object.Anchored = false
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.Massless = object ~= root
        end
    end

    if root then
        root.Anchored = true
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
end

local function rejectDeployment(player: Player, sessionId: number?, requestToken: string?, reason: string)
    warn(("[DroneService] deployment rejected for %s: %s"):format(player.Name, reason))
    stateEvent:FireClient(player, {
        state = "DeploymentRejected",
        sessionId = sessionId,
        requestToken = requestToken,
        reason = reason,
    })
end

local function deploy(
    player: Player,
    clientSessionId: number?,
    clientReleaseCFrame: CFrame?,
    requestToken: string?
)
    local now = os.clock()

    if typeof(clientSessionId) ~= "number" then
        rejectDeployment(player, nil, requestToken, "MissingSession")
        return
    end

    if typeof(requestToken) ~= "string" then
        rejectDeployment(player, clientSessionId, nil, "MissingRequestToken")
        return
    end
    local existing = activeDrones[player]
    local sessionState = getLifecycleState(player)
    local activeSessionId = player:GetAttribute("DroneSessionId")

    if sessionState ~= states.ThrowingDrone and sessionState ~= states.DroneReleased then
        rejectDeployment(player, activeSessionId, requestToken, "InvalidState")
        return
    end

    if typeof(activeSessionId) ~= "number" or clientSessionId ~= activeSessionId then
        rejectDeployment(player, activeSessionId, requestToken, "StaleSession")
        return
    end

    if not hasOwnedDroneTool(player) then
        rejectDeployment(player, activeSessionId, requestToken, "DroneToolNotOwned")
        return
    end

    if existing and existing.Parent then
        rejectDeployment(player, activeSessionId, requestToken, "DroneAlreadyActive")
        return
    end

    if existing then
        activeDrones[player] = nil
    end

    if now - (lastDeploy[player] or 0) < deployCooldown then
        rejectDeployment(player, activeSessionId, requestToken, "DeployRateLimited")
        return
    end

    lastDeploy[player] = now

    local source = getSource()
    if not source then
        rejectDeployment(player, activeSessionId, requestToken, "DroneSourceMissing")
        return
    end

    local releaseCFrame = clientReleaseCFrame
    if not isValidRelease(player, releaseCFrame) then
        rejectDeployment(player, activeSessionId, requestToken, "InvalidReleasePosition")
        return
    end

    local folder = getFolder()
    local oldDrone = folder:FindFirstChild(player.Name .. "_Drone")
    if oldDrone then
        oldDrone:Destroy()
    end

    local character = player.Character
    local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
    local drone = heldDrones[player]
    local reusingHeldDrone = drone and drone.Parent == character

    if not reusingHeldDrone then
        drone = source:Clone()
        drone.Name = player.Name .. "_Drone"
    else
        heldDrones[player] = nil
        drone:SetAttribute("ServerHeld", false)
        for _, object in ipairs(drone:GetDescendants()) do
            if object:IsA("Motor6D") and object.Part0 == characterRoot then
                object:Destroy()
            end
        end
    end

    drone.PrimaryPart = drone.PrimaryPart or drone:FindFirstChild("DroneRoot", true)

    if not drone.PrimaryPart then
        drone:Destroy()
        rejectDeployment(player, activeSessionId, requestToken, "DroneRootMissing")
        return
    end

    characterRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not characterRoot or not characterRoot:IsA("BasePart") then
        drone:Destroy()
        rejectDeployment(player, activeSessionId, requestToken, "CharacterRootMissing")
        return
    end

    local rootCF = characterRoot.CFrame
    local forward = rootCF.LookVector
    local deploymentPosition = rootCF.Position
        + forward * config.deployment.hoverForwardOffset
        + Vector3.yAxis * config.deployment.hoverVerticalOffset
    local launchCFrame = CFrame.new(releaseCFrame.Position) * releaseCFrame.Rotation
    local deploymentCFrame = CFrame.lookAt(deploymentPosition, deploymentPosition + forward, Vector3.yAxis)
        * config.DroneModelOrientationOffset * config.modelForwardCorrection

    local _, droneSize = drone:GetBoundingBox()
    local travel = deploymentCFrame.Position - releaseCFrame.Position
    local travelDistance = travel.Magnitude
    if travelDistance < 0.001 then
        drone:Destroy()
        rejectDeployment(player, activeSessionId, requestToken, "InvalidDeploymentDistance")
        return
    end

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {player.Character, drone}
    rayParams.IgnoreWater = true

    local direction = travel.Unit
    local clearance = math.max(droneSize.X, droneSize.Y, droneSize.Z) * 0.5 + 0.25
    local hit = Workspace:Raycast(releaseCFrame.Position, travel, rayParams)
    local targetPosition = deploymentCFrame.Position

    if hit then
        local safeDistance = hit.Distance - clearance
        if safeDistance <= 0.5 then
            drone:Destroy()
            rejectDeployment(player, activeSessionId, requestToken, "DeploymentBlocked")
            if getLifecycleState(player) ~= states.ExitingDrone then
                transitionPlayer(player, states.ExitingDrone, activeSessionId, "DeploymentBlocked", true, requestToken)
            end
            transitionPlayer(player, states.Unequipped, activeSessionId, "DeploymentBlockedComplete", true, requestToken)
            return
        end

        targetPosition = releaseCFrame.Position + direction * safeDistance
    end

    local floorHit = Workspace:Raycast(
        targetPosition + Vector3.yAxis * clearance,
        -Vector3.yAxis * (clearance * 2),
        rayParams
    )
    if floorHit then
        local minimumY = floorHit.Position.Y + droneSize.Y * 0.5 + 0.25
        targetPosition = Vector3.new(
            targetPosition.X,
            math.max(targetPosition.Y, minimumY),
            targetPosition.Z
        )
    end

    if targetPosition.Y - droneSize.Y * 0.5 <= Workspace.FallenPartsDestroyHeight + 1 then
        drone:Destroy()
        rejectDeployment(player, activeSessionId, requestToken, "DeploymentBelowMap")
        if getLifecycleState(player) ~= states.ExitingDrone then
            transitionPlayer(player, states.ExitingDrone, activeSessionId, "DeploymentBelowMap", true, requestToken)
        end
        transitionPlayer(player, states.Unequipped, activeSessionId, "DeploymentBelowMapComplete", true, requestToken)
        return
    end

    deploymentCFrame = CFrame.lookAt(targetPosition, targetPosition + forward, Vector3.yAxis)
        * config.DroneModelOrientationOffset * config.modelForwardCorrection

    drone:SetAttribute("HoverPosition", targetPosition)
    drone:SetAttribute("HoverOrientation", deploymentCFrame.Rotation)
    drone:SetAttribute("TargetPosition", targetPosition)
    drone:SetAttribute("TargetVelocity", Vector3.zero)
    drone:SetAttribute("TargetOrientation", deploymentCFrame.Rotation)
    drone:SetAttribute("CurrentSpeed", 0)

    drone:PivotTo(launchCFrame)
    drone.Name = player.Name .. "_Drone"
    drone.Parent = folder
    configureDrone(drone)

    activeDrones[player] = drone
    watchDrone(player, drone)
    local sessionId = player:GetAttribute("DroneSessionId")
    if typeof(sessionId) ~= "number" then
        drone:Destroy()
        rejectDeployment(player, activeSessionId, requestToken, "SessionLost")
        return
    end
    setDeployedTools(player)

    if not transitionPlayer(player, states.DroneReleased, sessionId, "DroneReleased", true, requestToken) then
        drone:Destroy()
        activeDrones[player] = nil
        return
    end

    if not transitionPlayer(player, states.DroneDeployed, sessionId, "DeploymentConfirmed", false) then
        return
    end

    stateEvent:FireClient(player, {
        state = states.DroneDeployed,
        sessionId = sessionId,
        drone = drone,
        requestToken = requestToken,
        reason = "DeploymentConfirmed",
    })

    task.spawn(function()
        local launchValue = Instance.new("CFrameValue")
        launchValue.Value = launchCFrame
        local launchConnection = launchValue:GetPropertyChangedSignal("Value"):Connect(function()
            if activeDrones[player] == drone and drone.Parent then
                drone:PivotTo(launchValue.Value)
            end
        end)

        local launchTween = TweenService:Create(
            launchValue,
            TweenInfo.new(config.deployment.launchDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Value = deploymentCFrame}
        )
        launchTween:Play()
        launchTween.Completed:Wait()
        launchConnection:Disconnect()
        launchValue:Destroy()

        if activeDrones[player] ~= drone or not drone.Parent then
            return
        end

    end)
end

function droneService:Init()
    deployEvent.OnServerEvent:Connect(deploy)

    stateEvent.OnServerEvent:Connect(function(player, payload)
        if typeof(payload) ~= "table"
            or typeof(payload.state) ~= "string"
            or (payload.state ~= states.HoldingDrone and typeof(payload.sessionId) ~= "number") then
            warn("[DroneLifecycle][Server] rejected malformed lifecycle update from " .. player.Name)
            return
        end

        local nextState = payload.state
        local requestedSessionId = payload.sessionId
        local requestToken = payload.requestToken
        local currentState = getLifecycleState(player)

        if nextState == states.HoldingDrone then
            if currentState ~= states.Unequipped or typeof(requestToken) ~= "string" then
                warn(("[DroneLifecycle][Server] rejected equip request from %s: cleanup or session pending")
                    :format(player.Name))
                return
            end

            if not createHeldDrone(player) then
                warn("[DroneService] could not create replicated HeldDrone for " .. player.Name)
                return
            end

            sessionCounters[player] = (sessionCounters[player] or 0) + 1
            local serverSessionId = sessionCounters[player]
            transitionPlayer(player, nextState, serverSessionId, payload.reason or "ClientEquipped", true, requestToken)
            return
        end

        if requestedSessionId ~= player:GetAttribute("DroneSessionId") then
            warn(("[DroneLifecycle][Server] rejected stale lifecycle update from %s for session %s")
                :format(player.Name, tostring(requestedSessionId)))
            return
        end

        if nextState == states.DroneDeployed
            or nextState == states.ExitingDrone
            or nextState == states.Unequipped then
            warn(("[DroneLifecycle][Server] rejected client-owned transition to %s from %s")
                :format(nextState, currentState))
            return
        end

        transitionPlayer(player, nextState, requestedSessionId, payload.reason or "ClientLifecycle", false, requestToken)
    end)

    remoteActivate.OnServerEvent:Connect(function(player, requestedSessionId)
        local now = os.clock()
        local character = player.Character
        local remote = character and character:FindFirstChild("Remote")
        local drone = activeDrones[player]
        local sessionId = player:GetAttribute("DroneSessionId")

        if typeof(requestedSessionId) ~= "number"
            or requestedSessionId ~= sessionId
            or player:GetAttribute("DroneSessionState") ~= states.ControllingDrone
            or not remote
            or not remote:IsA("Tool")
            or remote.Parent ~= character
            or not drone
            or not drone.Parent
            or now - (lastRemoteActivation[player] or 0) < 0.25 then
            warn("[DroneLifecycle][Server] rejected remote activation for " .. player.Name)
            return
        end

        lastRemoteActivation[player] = now
        drone:SetAttribute("ControlsEnabled", true)
        stateEvent:FireClient(player, {
            state = states.ControllingDrone,
            sessionId = sessionId,
            drone = drone,
            reason = "RemoteActivated",
        })
    end)

    cleanupEvent.OnServerEvent:Connect(function(player, requestedSessionId, cleanupToken)
        removeDrone(player, requestedSessionId, cleanupToken)
    end)
end

function droneService:Start()
    Players.PlayerAdded:Connect(function(player)
        player.CharacterAdded:Connect(function()
            watchBackpack(player)
            task.wait(0.2)
            giveTools(player)
            task.delay(1, giveTools, player)
        end)

        player.ChildAdded:Connect(function(child)
            if child:IsA("Backpack") then
                watchBackpack(player)
            end
        end)

        task.defer(function()
            watchBackpack(player)
            giveTools(player)
            task.delay(1, giveTools, player)
        end)

        player.CharacterRemoving:Connect(function()
            removeDrone(player)
        end)
    end)

    for _, player in ipairs(Players:GetPlayers()) do
        player.ChildAdded:Connect(function(child)
            if child:IsA("Backpack") then
                watchBackpack(player)
            end
        end)

        task.defer(function()
            watchBackpack(player)
            giveTools(player)
            task.delay(1, giveTools, player)
        end)

        player.CharacterRemoving:Connect(function()
            removeDrone(player)
        end)
    end

    Players.PlayerRemoving:Connect(function(player)
        removeDrone(player)
        sessionCounters[player] = nil
        lastRemoteActivation[player] = nil
        droneConnections[player] = nil
        local connection = backpackConnections[player]
        if connection then
            connection:Disconnect()
            backpackConnections[player] = nil
            watchedBackpacks[player] = nil
        end
    end)
end

return droneService

