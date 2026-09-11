--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local states = require(ReplicatedStorage.Shared.Drone.DroneStates)
local animationController = require(script.Parent.DroneAnimationController)
local remoteController = require(script.Parent.RemoteController)
local droneCameraController = require(script.Parent.DroneCameraController)
local weaponHudSignals = require(ReplicatedStorage.WeaponModules.WeaponHUDSignals)

local deployEvent = ReplicatedStorage.Remotes:WaitForChild("DroneDeploy")
local cleanupEvent = ReplicatedStorage.Remotes:WaitForChild("DroneCleanup")
local stateEvent = ReplicatedStorage.Remotes:WaitForChild("DroneStateChanged")
local remoteActivate = ReplicatedStorage.Remotes:WaitForChild("RemoteActivate")

local controller = {}

local currentTool: Tool?
local heldModel: Model?
local flightProxy: Model?
local handWeld: Weld?
local handReleaseAttachment: Attachment?
local animatedDroneJoint: Motor6D?
local hiddenTemplateParts: {BasePart} = {}
local hiddenWeaponParts: {BasePart} = {}
local toolConnections: {RBXScriptConnection} = {}
local characterConnections: {RBXScriptConnection} = {}
local inputConnection: RBXScriptConnection?
local characterConnection: RBXScriptConnection?
local releaseConnection: RBXScriptConnection?
local testRequestEvent: BindableEvent?
local testRequestConnection: RBXScriptConnection?
local propellerConnection: RBXScriptConnection?

local currentState = states.Unequipped
local sessionId: number?
local sessionGeneration = 0
local authoritativeSessionId: number?
local requestTokenCounter = 0
local equipRequestToken: string?
local deploymentRequestToken: string?
local cleanupRequestToken: string?
local cleanupSessionId: number?
local cleanupPending = false
local equipped = false
local holdingReady = false
local savedWalkSpeed: number?
local cleanupInProgress = false
local started = false
local proxyReleasedAt: number?

local function notifyServerState(nextState: string, reason: string)
    local requestToken = nextState == states.HoldingDrone
        and equipRequestToken
        or deploymentRequestToken

    if nextState ~= states.HoldingDrone and not sessionId then
        return
    end

    if nextState == states.ExitingDrone
        or nextState == states.Unequipped
        or nextState == states.DroneReleased
        or nextState == states.DroneDeployed then
        return
    end

    stateEvent:FireServer({
        state = nextState,
        sessionId = sessionId,
        requestToken = requestToken,
        reason = reason,
    })
end

local function transitionTo(nextState: string, reason: string): boolean
    if currentState == nextState then
        return true
    end

    if not states.CanTransition(currentState, nextState) then
        warn(("[DroneLifecycle][Client] rejected transition %s -> %s (%s)"):format(currentState, nextState, reason))
        return false
    end

    local previousState = currentState
    currentState = nextState
    player:SetAttribute("DroneClientState", currentState)
    player:SetAttribute("DroneClientSessionId", sessionId)
    print(("[DroneLifecycle][Client] %s -> %s | session=%s | %s")
        :format(previousState, nextState, tostring(sessionId), reason))
    notifyServerState(nextState, reason)
    return true
end

local function nextRequestToken(prefix: string): string
    requestTokenCounter += 1
    return ("%s-%d"):format(prefix, requestTokenCounter)
end

local function beginSession()
    sessionGeneration += 1
    sessionId = nil
    authoritativeSessionId = nil
    equipRequestToken = nextRequestToken("equip")
    deploymentRequestToken = nil
    cleanupRequestToken = nil
    cleanupSessionId = nil
    cleanupPending = false
    player:SetAttribute("DroneClientSessionId", nil)
end

local function invalidateSession()
    sessionGeneration += 1
    sessionId = nil
    authoritativeSessionId = nil
    equipRequestToken = nil
    deploymentRequestToken = nil
    cleanupRequestToken = nil
    cleanupSessionId = nil
    cleanupPending = false
    player:SetAttribute("DroneClientSessionId", nil)
end

local function isCurrentSession(generation: number): boolean
    return generation == sessionGeneration
end

local function disconnectTool()
    for _, connection in ipairs(toolConnections) do
        connection:Disconnect()
    end

    table.clear(toolConnections)
    currentTool = nil
end

local function disconnectCharacter()
    for _, connection in ipairs(characterConnections) do
        connection:Disconnect()
    end

    table.clear(characterConnections)
end

local function destroyFlightProxy()
    if flightProxy then
        flightProxy:Destroy()
        flightProxy = nil
    end
    proxyReleasedAt = nil
end

local function stopPropellerAnimation()
    if propellerConnection then
        propellerConnection:Disconnect()
        propellerConnection = nil
    end
end

local function startPropellerAnimation()
    if propellerConnection then
        return
    end

    local angles: {[Model]: number} = {}
    propellerConnection = RunService.RenderStepped:Connect(function(dt)
        local activeDrones = Workspace:FindFirstChild("ActiveDrones")
        if not activeDrones then
            return
        end

        for _, drone in ipairs(activeDrones:GetChildren()) do
            if drone:IsA("Model") then
                local motor = drone:FindFirstChild("PropellerMotor", true)
                if motor and motor:IsA("Motor6D")
                    and motor.Part1
                    and motor.Part1.Name == "Cylinder.002" then
                    angles[drone] = (angles[drone] or 0)
                        + config.propeller.rotationSpeed * dt
                    motor.Transform = CFrame.Angles(0, 0, angles[drone] % (math.pi * 2))
                end
            end
        end
    end)
end

local function detachHeldDroneForFlight(releaseCFrame: CFrame): boolean
    local model = heldModel
    if not model then
        return false
    end

    if model:GetAttribute("ServerHeld") == true then
        if animatedDroneJoint then
            animatedDroneJoint = nil
        end
        proxyReleasedAt = nil
        return true
    end

    if handWeld then
        handWeld:Destroy()
        handWeld = nil
    end

    if handReleaseAttachment then
        handReleaseAttachment:Destroy()
        handReleaseAttachment = nil
    end

    if animatedDroneJoint then
        animatedDroneJoint:Destroy()
        animatedDroneJoint = nil
    end

    model:PivotTo(releaseCFrame)
    model.Name = "DroneFlightProxy"
    model.Parent = Workspace

    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") then
            object.Anchored = true
            object.Massless = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
        end
    end

    flightProxy = model
    heldModel = nil
    proxyReleasedAt = os.clock()
    return true
end

local function removeHeldDrone()
    if handWeld then
        handWeld:Destroy()
        handWeld = nil
    end

    if handReleaseAttachment then
        handReleaseAttachment:Destroy()
        handReleaseAttachment = nil
    end

    if animatedDroneJoint then
        animatedDroneJoint:Destroy()
        animatedDroneJoint = nil
    end

    if heldModel then
        heldModel:Destroy()
        heldModel = nil
    end
end

local function restoreTemplateVisibility()
    for _, object in ipairs(hiddenTemplateParts) do
        if object.Parent then
            object.LocalTransparencyModifier = 0
        end
    end
    table.clear(hiddenTemplateParts)

    for _, object in ipairs(hiddenWeaponParts) do
        if object.Parent then
            object.LocalTransparencyModifier = 0
        end
    end
    table.clear(hiddenWeaponParts)
end

local function hideWeaponPresentation()
    local character = player.Character
    if not character then
        return
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") and child.Name ~= "Drone" and child.Name ~= "Remote" then
            for _, object in ipairs(child:GetDescendants()) do
                if object:IsA("BasePart") then
                    object.LocalTransparencyModifier = 1
                    table.insert(hiddenWeaponParts, object)
                end
            end
        end
    end

    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("BasePart") then
            local ancestor = object.Parent
            local isHolster = false
            while ancestor and ancestor ~= character do
                if ancestor:IsA("Model") and string.sub(ancestor.Name, 1, 7) == "Holster_" then
                    isHolster = true
                    break
                end
                ancestor = ancestor.Parent
            end

            if isHolster then
                object.LocalTransparencyModifier = 1
                table.insert(hiddenWeaponParts, object)
            end
        end
    end
end

local function weldHeldDroneParts(model: Model, root: BasePart)
    local bodyAttach = model:FindFirstChild("BodyAttach", true)
    if not bodyAttach or not bodyAttach:IsA("BasePart") or bodyAttach == root then
        return
    end

    for _, object in ipairs(root:GetChildren()) do
        if object:IsA("WeldConstraint") and object.Name == "HeldDroneBodyAttachWeld" then
            if object.Part0 == root and object.Part1 == bodyAttach
                or object.Part0 == bodyAttach and object.Part1 == root then
                return
            end
            object:Destroy()
        end
    end

    local weld = Instance.new("WeldConstraint")
    weld.Name = "HeldDroneBodyAttachWeld"
    weld.Part0 = root
    weld.Part1 = bodyAttach
    weld.Parent = root
end

local function restoreWalkSpeed()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and savedWalkSpeed then
        humanoid.WalkSpeed = savedWalkSpeed
    end
    savedWalkSpeed = nil
end

local function attachToHand(): boolean
    local character = player.Character
    if not character then
        warn("[DroneController] Character was not found")
        return false
    end

    local model = character:FindFirstChild("HeldDrone")
    if not model then
        model = character:WaitForChild("HeldDrone", 2)
    end

    if not model or not model:IsA("Model") then
        warn("[DroneController] replicated HeldDrone was not found")
        return false
    end

    local bodyAttach = model:FindFirstChild("BodyAttach", true)
    local motor = model:FindFirstChild("Motor6D")
    if not bodyAttach or not bodyAttach:IsA("BasePart")
        or not motor or not motor:IsA("Motor6D") then
        warn("[DroneController] replicated HeldDrone joint was invalid")
        return false
    end

    heldModel = model
    animatedDroneJoint = motor
    return true
end

local cleanup
local completeCleanup

local function releaseDrone(generation: number)
    if releaseConnection then
        releaseConnection:Disconnect()
        releaseConnection = nil
    end

    if not isCurrentSession(generation) or currentState ~= states.ThrowingDrone then
        return
    end

    local releaseCFrame = heldModel and heldModel:GetPivot()
    if not releaseCFrame then
        cleanup("DroneReleaseMissing", true)
        return
    end

    print(("[DroneLifecycle][Client] release position=(%.2f, %.2f, %.2f) look=(%.2f, %.2f, %.2f)")
        :format(releaseCFrame.Position.X, releaseCFrame.Position.Y, releaseCFrame.Position.Z,
            releaseCFrame.LookVector.X, releaseCFrame.LookVector.Y, releaseCFrame.LookVector.Z))
    if not transitionTo(states.DroneReleased, "DroneReleased") then
        cleanup("DroneReleaseStateFailed", true)
        return
    end

    if not detachHeldDroneForFlight(releaseCFrame) then
        cleanup("DroneReleaseMissing", true)
        return
    end

    deployEvent:FireServer(sessionId, releaseCFrame, deploymentRequestToken)
end

local function requestDeployment(): (boolean, string?)
    if cleanupPending then
        warn("[DroneLifecycle][Client] deployment rejected: CleanupPending")
        return false, "CleanupPending"
    end

    if currentState ~= states.HoldingDrone then
        warn("[DroneLifecycle][Client] deployment rejected: InvalidState")
        return false, "InvalidState"
    end

    if deploymentRequestToken then
        warn("[DroneLifecycle][Client] deployment rejected: RequestPending")
        return false, "RequestPending"
    end

    hideWeaponPresentation()

    if not equipped then
        warn("[DroneLifecycle][Client] deployment rejected: DroneNotEquipped")
        return false, "DroneNotEquipped"
    end

    if not holdingReady then
        warn("[DroneLifecycle][Client] deployment rejected: HoldingAnimationNotReady")
        return false, "HoldingAnimationNotReady"
    end

    if not authoritativeSessionId or not sessionId then
        warn("[DroneLifecycle][Client] deployment rejected: SessionNotConfirmed")
        return false, "SessionNotConfirmed"
    end

    deploymentRequestToken = nextRequestToken("deploy")
    local generation = sessionGeneration
    if not transitionTo(states.ThrowingDrone, "DeployInput") then
        deploymentRequestToken = nil
        return false, "InvalidTransition"
    end

    local throwTrack = animationController:PlayDroneThrow()
    if not throwTrack then
        cleanup("DroneThrowAnimationFailed", true)
        return false, "ThrowAnimationFailed"
    end

    local released = false
    local releaseCallbackCount = 0
    local function releaseOnce()
        releaseCallbackCount += 1
        print(("[DroneLifecycle][Client] release callback=%d time=%.4f session=%s")
            :format(releaseCallbackCount, throwTrack.TimePosition, tostring(sessionId)))
        if released then
            return
        end
        released = true
        releaseDrone(generation)
    end

    releaseConnection = RunService.PreAnimation:Connect(function()
        if not isCurrentSession(generation) or currentState ~= states.ThrowingDrone then
            releaseConnection:Disconnect()
            releaseConnection = nil
            return
        end

        if throwTrack.TimePosition >= config.animationTiming.droneReleaseTime then
            releaseOnce()
        end
    end)
    return true, nil
end

local function setupTestHarness()
    if not RunService:IsStudio() or testRequestEvent then
        return
    end

    local event = Instance.new("BindableEvent")
    event.Name = "DroneRequestDeploymentTest"
    event.Parent = player:WaitForChild("PlayerScripts")
    testRequestEvent = event
    testRequestConnection = event.Event:Connect(function()
        requestDeployment()
    end)
end

local function clearTestHarness()
    if testRequestConnection then
        testRequestConnection:Disconnect()
        testRequestConnection = nil
    end

    if testRequestEvent then
        testRequestEvent:Destroy()
        testRequestEvent = nil
    end
end

local function onDroneEquipped(tool: Tool)
    local character = player.Character
    if tool.Parent ~= character or currentState ~= states.Unequipped then
        return
    end

    beginSession()
    setupTestHarness()
    equipped = true
    holdingReady = false

    weaponHudSignals.WeaponUnequipped:Fire()
    hideWeaponPresentation()
    removeHeldDrone()
    restoreTemplateVisibility()

    if not transitionTo(states.HoldingDrone, "DroneToolEquipped") then
        cleanup("DroneStateFailed", false)
        return
    end

    if attachToHand() then
        local holdingTrack = animationController:PlayDroneHolding()
        holdingReady = holdingTrack ~= nil and holdingTrack.IsPlaying
        if not holdingReady then
            cleanup("DroneHoldingAnimationFailed", false)
        end
    else
        cleanup("DroneAttachFailed", true)
    end
end

cleanup = function(reason: string, notifyServer: boolean, serverSessionId: number?, serverCleanupToken: string?)
    if cleanupInProgress or cleanupPending then
        return
    end
    cleanupInProgress = true

    local activeSessionId = sessionId or serverSessionId
    local hadSession = currentState ~= states.Unequipped
        or heldModel ~= nil
        or remoteController:HasRemote()
        or activeSessionId ~= nil

    if not hadSession then
        cleanupInProgress = false
        return
    end

    cleanupPending = true
    cleanupSessionId = activeSessionId
    cleanupRequestToken = serverCleanupToken or nextRequestToken("cleanup")

    if currentState ~= states.ExitingDrone then
        transitionTo(states.ExitingDrone, reason)
    end

    sessionGeneration += 1
    clearTestHarness()
    if releaseConnection then
        releaseConnection:Disconnect()
        releaseConnection = nil
    end
    animationController:Cleanup()
    stopPropellerAnimation()
    remoteController:Destroy()
    droneCameraController:Exit()
    destroyFlightProxy()
    removeHeldDrone()
    restoreTemplateVisibility()
    restoreWalkSpeed()
    equipped = false
    holdingReady = false
    disconnectTool()

    if notifyServer and activeSessionId then
        cleanupEvent:FireServer(activeSessionId, cleanupRequestToken)
    end

    cleanupInProgress = false

    task.delay(1.5, function()
        if cleanupPending and cleanupSessionId == activeSessionId then
            completeCleanup(activeSessionId, "CleanupTimeout")
        end
    end)
end

completeCleanup = function(eventSessionId: number?, reason: string)
    if not cleanupPending then
        warn("[DroneLifecycle][Client] ignored cleanup confirmation without a pending cleanup")
        return
    end

    if cleanupSessionId ~= eventSessionId then
        warn((("[DroneLifecycle][Client] ignored stale cleanup confirmation %s; active session is %s")
            :format(tostring(eventSessionId), tostring(cleanupSessionId))))
        return
    end

    invalidateSession()
    if currentState == states.ExitingDrone then
        transitionTo(states.Unequipped, reason)
    end
end

local function onDroneUnequipped(tool: Tool)
    task.defer(function()
        if tool.Parent == player.Character then
            return
        end

        local unequippedBeforeRelease = currentState == states.ThrowingDrone
            and heldModel ~= nil
        if currentTool == tool
            and (currentState == states.HoldingDrone or unequippedBeforeRelease) then
            cleanup("DroneToolUnequipped", true)
        end
    end)
end

local function connectTool(tool: Tool)
    if currentTool == tool then
        return
    end

    disconnectTool()
    currentTool = tool

    table.insert(toolConnections, tool.Equipped:Connect(function()
        onDroneEquipped(tool)
    end))
    table.insert(toolConnections, tool.Unequipped:Connect(function()
        onDroneUnequipped(tool)
    end))
end

local function findDroneTool(): Tool?
    local character = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")
    local tool = character and character:FindFirstChild("Drone")
        or backpack and backpack:FindFirstChild("Drone")
    return tool and tool:IsA("Tool") and tool or nil
end

local function parseStateEvent(payload)
    if type(payload) == "table" then
        return payload.state, payload.sessionId, payload.reason, payload.requestToken
    end
    return payload, nil, "LegacyStateEvent", nil
end

local function acceptServerSession(nextState: string, eventSessionId: number?, requestToken: string?): boolean
    if nextState == states.HoldingDrone then
        if currentState ~= states.HoldingDrone
            or typeof(eventSessionId) ~= "number"
            or requestToken ~= equipRequestToken then
            warn("[DroneLifecycle][Client] ignored stale HoldingDrone session response")
            return false
        end

        authoritativeSessionId = eventSessionId
        sessionId = eventSessionId
        player:SetAttribute("DroneClientSessionId", sessionId)
        return true
    end

    if typeof(eventSessionId) ~= "number"
        or typeof(sessionId) ~= "number"
        or eventSessionId ~= sessionId
        or (authoritativeSessionId and eventSessionId ~= authoritativeSessionId) then
        warn(("[DroneLifecycle][Client] ignored stale server session %s; active session is %s")
            :format(tostring(eventSessionId), tostring(sessionId)))
        return false
    end

    return true
end

local function enterDroneControl(generation: number)
    if not isCurrentSession(generation) or currentState ~= states.RemoteIdle then
        return
    end

    if not transitionTo(states.EnteringFPV, "PreviewReady") then
        return
    end

    if not droneCameraController:Enter() then
        cleanup("ScreenTargetMissing", true)
        return
    end

    local deadline = os.clock() + config.camera.transitionTime + 0.5
    while isCurrentSession(generation)
        and currentState == states.EnteringFPV
        and not droneCameraController:IsTransitionComplete()
        and os.clock() < deadline do
        task.wait()
    end

    if not isCurrentSession(generation) or currentState ~= states.EnteringFPV then
        return
    end

    if not droneCameraController:IsTransitionComplete() then
        cleanup("CameraTransitionTimeout", true)
        return
    end

    if transitionTo(states.ControllingDrone, "ScreenTransitionComplete") then
        remoteActivate:FireServer(sessionId)
    end
end

local function startRemote(generation: number)
    if not isCurrentSession(generation) or currentState ~= states.DroneDeployed then
        return
    end

    if not remoteController:Create() then
        cleanup("RemoteCreateFailed", true)
        return
    end

    hideWeaponPresentation()

    if not transitionTo(states.EquippingRemote, "RemoteCreated") then
        cleanup("RemoteStateFailed", true)
        return
    end

    animationController:PlayRemoteEquip()
    task.delay(config.animationTiming.remoteEquipReadyTime, function()
        if not isCurrentSession(generation) or currentState ~= states.EquippingRemote then
            return
        end

        animationController:PlayRemoteIdle()
        if not transitionTo(states.RemoteIdle, "RemoteEquipReady") then
            return
        end

        enterDroneControl(generation)
    end)
end

local function handleServerState(payload)
    local nextState, eventSessionId, reason, requestToken = parseStateEvent(payload)
    if not nextState then
        return
    end

    print(("[DroneLifecycle][Client] server event %s | session=%s | local=%s/%s | %s")
        :format(nextState, tostring(eventSessionId), currentState, tostring(sessionId), reason or ""))

    if nextState == "DeploymentRejected" then
        if eventSessionId ~= sessionId or requestToken ~= deploymentRequestToken then
            warn("[DroneLifecycle][Client] ignored stale deployment rejection")
            return
        end

        warn(("[DroneLifecycle][Client] deployment rejected: %s"):format(reason or "Unknown"))
        deploymentRequestToken = nil
        cleanup("DeploymentRejected", true, eventSessionId)
        return
    end

    if nextState == states.ExitingDrone then
        if eventSessionId ~= sessionId then
            warn("[DroneLifecycle][Client] ignored stale cleanup start")
            return
        end

        cleanup(reason or states.ExitingDrone, false, eventSessionId, requestToken)
        return
    end

    if nextState == states.Unequipped then
        completeCleanup(eventSessionId, reason or states.Unequipped)
        return
    end

    if nextState == states.DroneDeployed
        and requestToken ~= deploymentRequestToken then
        warn("[DroneLifecycle][Client] ignored stale deployment response")
        return
    end

    if not acceptServerSession(nextState, eventSessionId, requestToken) then
        return
    end

    if nextState == states.HoldingDrone or nextState == states.ThrowingDrone then
        transitionTo(nextState, reason or "ServerLifecycleAck")
    elseif nextState == states.DroneDeployed then
        deploymentRequestToken = nil
        startPropellerAnimation()
        if not transitionTo(states.DroneDeployed, reason or "ServerDeploymentConfirmed") then
            return
        end
        local handoffGap = proxyReleasedAt and (os.clock() - proxyReleasedAt) or 0
        destroyFlightProxy()
        heldModel = nil
        animatedDroneJoint = nil
        print(("[DroneLifecycle][Client] visual handoff gap=%.4fs"):format(handoffGap))
        startRemote(sessionGeneration)
    elseif nextState == states.EquippingRemote then
        if transitionTo(states.EquippingRemote, reason or "ServerRemoteEquipping") then
            startRemote(sessionGeneration)
        end
    elseif nextState == states.RemoteIdle then
        if transitionTo(states.RemoteIdle, reason or "ServerRemoteIdle") then
            animationController:PlayRemoteIdle()
            enterDroneControl(sessionGeneration)
        end
    elseif nextState == states.EnteringFPV then
        transitionTo(states.EnteringFPV, reason or "ServerEnteringFPV")
    elseif nextState == states.ControllingDrone then
        transitionTo(states.ControllingDrone, reason or "ServerControllingDrone")
    end
end

function controller:Init()
end

function controller:Start()
    if started then
        return
    end
    started = true
    player:SetAttribute("DroneClientState", currentState)
    player:SetAttribute("DroneClientSessionId", sessionId)

    local backpack = player:WaitForChild("Backpack")
    table.insert(characterConnections, backpack.ChildAdded:Connect(function(child)
        if child:IsA("Tool") and child.Name == "Drone" then
            connectTool(child)
        end
    end))

    local function setupCharacter(character: Model)
        disconnectCharacter()

        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            table.insert(characterConnections, humanoid.Died:Connect(function()
                cleanup("CharacterDied", true)
            end))
        end

        table.insert(characterConnections, character.ChildAdded:Connect(function(child)
            if child:IsA("Tool") and child.Name == "Drone" then
                connectTool(child)
            end
        end))

        table.insert(characterConnections, character.ChildRemoved:Connect(function(child)
            if (child:IsA("Tool") and child.Name == "Remote") or child.Name == "HeldRemote" then
                if currentState ~= states.Unequipped then
                    cleanup("RemoteLost", true)
                end
            end
        end))

        local tool = findDroneTool()
        if tool then
            connectTool(tool)
            if tool.Parent == character then
                task.defer(onDroneEquipped, tool)
            end
        end
    end

    characterConnection = player.CharacterAdded:Connect(function(character)
        cleanup("CharacterAdded", false)
        setupCharacter(character)
    end)

    if player.Character then
        setupCharacter(player.Character)
    end

    stateEvent.OnClientEvent:Connect(handleServerState)

    inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or input.KeyCode ~= config.input.deploy then
            return
        end
        requestDeployment()
    end)

    player.CharacterRemoving:Connect(function()
        cleanup("CharacterRemoving", false)
    end)
end

function controller:RequestDeployment(): boolean
    return requestDeployment()
end

function controller:GetState(): string
    return currentState
end

function controller:GetSessionId(): number?
    return sessionId
end

return controller
