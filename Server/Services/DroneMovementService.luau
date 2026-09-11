--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local inputEvent = ReplicatedStorage.Remotes:WaitForChild("DroneInput")

local function getPhysicalOrientation(pivot: CFrame): CFrame
    return pivot * config.modelForwardCorrection
end

local movementService = {}

type InputState = {
    forward: number,
    sideways: number,
    speed: number,
    roll: number,
    vertical: number,
    yaw: number,
}

type DroneState = {
    drone: Model,
    velocity: Vector3,
    targetPosition: Vector3,
    targetVelocity: Vector3,
    targetOrientation: CFrame,
    currentSpeed: number,
    speedSetting: number,
    roll: number,
    pitch: number,
    propellerMotor: Motor6D?,
    propellerAngle: number,
    origin: Vector3,
    hoverTargetPosition: Vector3?,
    hoverAnchorPosition: Vector3?,
    hoverVisualOffset: Vector3,
    hoverTime: number,
    orientation: CFrame,
    input: InputState,
    lastInput: number,
}

local states: {[Player]: DroneState} = {}
local inputDelay = 1 / 30

local function setupPropeller(drone: Model): Motor6D?
    local blade = drone:FindFirstChild("Cylinder.002", true)
    local hub = drone:FindFirstChild("Cylinder", true)
    local root = drone.PrimaryPart
    if not blade or not blade:IsA("BasePart") or not hub or not hub:IsA("BasePart") or not root then
        return nil
    end

    local existing = drone:FindFirstChild("PropellerMotor", true)
    if existing and existing:IsA("Motor6D") and existing.Part1 == blade then
        return existing
    end

    for _, object in ipairs(drone:GetDescendants()) do
        if object:IsA("WeldConstraint") and (object.Part0 == blade or object.Part1 == blade) then
            object:Destroy()
        elseif object:IsA("Weld") and (object.Part0 == blade or object.Part1 == blade) then
            object:Destroy()
        end
    end

    local motor = Instance.new("Motor6D")
    motor.Name = "PropellerMotor"
    motor.Part0 = hub
    motor.Part1 = blade
    motor.C0 = hub.CFrame:ToObjectSpace(blade.CFrame)
    motor.C1 = CFrame.identity
    motor.Parent = hub
    return motor
end

local function approach(current: number, target: number, amount: number): number
    if current < target then
        return math.min(current + amount, target)
    end
    return math.max(current - amount, target)
end

local function validNumber(value): boolean
    return typeof(value) == "number" and value == value and math.abs(value) <= 1
end

local function readInput(value): InputState?
    if typeof(value) ~= "table" then
        return nil
    end

    if not validNumber(value.forward)
        or not validNumber(value.sideways)
        or not validNumber(value.speed)
        or not validNumber(value.roll)
        or not validNumber(value.vertical)
        or not validNumber(value.yaw) then
        return nil
    end

    return {
        forward = math.clamp(value.forward, -1, 1),
        sideways = math.clamp(value.sideways, -1, 1),
        speed = math.clamp(value.speed, -1, 1),
        roll = math.clamp(value.roll, -1, 1),
        vertical = math.clamp(value.vertical, -1, 1),
        yaw = math.clamp(value.yaw, -1, 1),
    }
end

local function getDrone(player: Player): Model?
    local folder = Workspace:FindFirstChild("ActiveDrones")
    local drone = folder and folder:FindFirstChild(player.Name .. "_Drone")
    return drone and drone:IsA("Model") and drone or nil
end

local function hasEquippedRemote(player: Player): boolean
    local character = player.Character
    local remote = character and character:FindFirstChild("Remote")
    return remote ~= nil and remote:IsA("Tool") and remote.Parent == character
end

local function getState(player: Player, drone: Model): DroneState
    local state = states[player]
    if state and state.drone == drone then
        return state
    end

    local pivot = drone:GetPivot()
    local hoverPosition = drone:GetAttribute("HoverPosition")
    local hoverOrientation = drone:GetAttribute("HoverOrientation")
    local targetPosition = typeof(hoverPosition) == "Vector3" and hoverPosition or pivot.Position
    local targetOrientation = typeof(hoverOrientation) == "CFrame" and hoverOrientation.Rotation or pivot.Rotation

    state = {
        drone = drone,
        velocity = Vector3.zero,
        targetPosition = targetPosition,
        targetVelocity = Vector3.zero,
        targetOrientation = targetOrientation,
        currentSpeed = 0,
        speedSetting = config.movement.normalSpeed,
        roll = 0,
        pitch = 0,
        propellerMotor = setupPropeller(drone),
        propellerAngle = 0,
        origin = pivot.Position,
        hoverTargetPosition = pivot.Position,
        hoverAnchorPosition = pivot.Position,
        hoverVisualOffset = Vector3.zero,
        hoverTime = 0,
        orientation = targetOrientation,
        input = {forward = 0, sideways = 0, speed = 0, roll = 0, vertical = 0, yaw = 0},
        lastInput = os.clock(),
    }
    states[player] = state
    return state
end

local function limitPosition(player: Player, position: Vector3, origin: Vector3): Vector3
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local minimumY = (root and root.Position.Y or origin.Y) + config.deployment.hoverVerticalOffset
    local maximumY = minimumY + 80
    local offset = position - origin
    local horizontal = Vector3.new(offset.X, 0, offset.Z)

    local maximumDistance = math.max(config.movement.maximumFlightDistance, 1)
    if horizontal.Magnitude > maximumDistance then
        horizontal = horizontal.Unit * maximumDistance
    end

    return Vector3.new(origin.X + horizontal.X, math.clamp(position.Y, minimumY, maximumY), origin.Z + horizontal.Z)
end

local function limitCollisionPosition(player: Player, drone: Model, position: Vector3, origin: Vector3): Vector3
    local displacement = position - origin
    if displacement.Magnitude < 0.001 then
        return position
    end

    local _, bounds = drone:GetBoundingBox()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {drone, player.Character}

    local hit = Workspace:Blockcast(
        CFrame.new(origin),
        bounds * 0.96,
        displacement,
        params
    )
    if not hit then
        return position
    end

    local safeDistance = math.max(0, hit.Distance - 0.08)
    return origin + displacement.Unit * safeDistance
end

local function limitVerticalPosition(player: Player, drone: Model, position: Vector3, origin: Vector3): Vector3
    local deltaY = position.Y - origin.Y
    if math.abs(deltaY) < 0.001 then
        return position
    end

    local _, size = drone:GetBoundingBox()
    local halfHeight = size.Y * 0.5
    local clearance = 0.1
    local rayOrigin = origin + Vector3.yAxis * (deltaY > 0 and halfHeight or -halfHeight)
    local rayDirection = Vector3.yAxis * deltaY
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {drone, player.Character}

    local hit = Workspace:Raycast(rayOrigin, rayDirection, params)
    if not hit then
        return position
    end

    local safeY = deltaY > 0
        and hit.Position.Y - halfHeight - clearance
        or hit.Position.Y + halfHeight + clearance

    return Vector3.new(position.X, safeY, position.Z)
end

local function updateDrone(player: Player, state: DroneState, dt: number)
    local drone = getDrone(player)
    if not drone or not drone.PrimaryPart then
        states[player] = nil
        return
    end

    if os.clock() - state.lastInput > config.movement.inputTimeout then
        state.input = {forward = 0, sideways = 0, speed = 0, roll = 0, vertical = 0, yaw = 0}
    end

    local pivot = drone:GetPivot()
    local basePivot = pivot
    local physicalOrientation = getPhysicalOrientation(basePivot)
    local movementOrientation = physicalOrientation * config.DroneModelOrientationOffset
    local forward = Vector3.new(
        movementOrientation.LookVector.X,
        0,
        movementOrientation.LookVector.Z
    )
    local right = Vector3.new(
        movementOrientation.RightVector.X,
        0,
        movementOrientation.RightVector.Z
    )
    if forward.Magnitude < 0.001 then
        forward = Vector3.zAxis
    else
        forward = forward.Unit
    end

    if right.Magnitude < 0.001 then
        right = Vector3.xAxis
    else
        right = right.Unit
    end

    local pitchInput = 0
    local rollInput = math.clamp(state.input.roll, -1, 1)
    local rudderInput = math.clamp(state.input.yaw, -1, 1)
    local verticalInput = math.clamp(state.input.vertical, -1, 1)

    local throttle = math.clamp(state.input.speed, -1, 1)
    state.speedSetting = math.clamp(
        state.speedSetting + throttle * config.movement.speedChangeRate * dt,
        config.movement.minimumSpeed,
        config.movement.maximumSpeed
    )

    local hasFlightInput = math.abs(state.input.forward) > 0.01
        or math.abs(state.input.sideways) > 0.01
        or math.abs(verticalInput) > 0.01
        or math.abs(rollInput) > 0.01
        or math.abs(rudderInput) > 0.01
        or math.abs(throttle) > 0.01

    local forwardSpeed = state.velocity:Dot(forward)
    local sidewaysSpeed = state.velocity:Dot(right)
    local returningToHover = not hasFlightInput
        and (state.velocity.Magnitude > 0.1
            or math.abs(state.pitch) > 0.1
            or math.abs(state.roll) > 0.1)

    if hasFlightInput then
        local targetForwardSpeed = state.input.forward * state.speedSetting
        local bankingWithoutForwardInput = math.abs(state.input.forward) <= 0.01
            and math.abs(rollInput) > 0.01
        if bankingWithoutForwardInput
            and forwardSpeed < config.movement.turnAssistSpeed then
            targetForwardSpeed = config.movement.turnAssistSpeed
        end

        local forwardRate = math.abs(targetForwardSpeed) > math.abs(forwardSpeed)
            and config.movement.acceleration
            or config.movement.deceleration
        forwardSpeed = approach(forwardSpeed, targetForwardSpeed, forwardRate * dt)

        local targetSidewaysSpeed = state.input.sideways * state.speedSetting
        local sidewaysRate = math.abs(targetSidewaysSpeed) > math.abs(sidewaysSpeed)
            and config.movement.acceleration
            or config.movement.deceleration
        sidewaysSpeed = approach(sidewaysSpeed, targetSidewaysSpeed, sidewaysRate * dt)

        local verticalLimit = verticalInput >= 0
            and config.movement.maximumClimbSpeed
            or config.movement.maximumDescentSpeed
        local targetVerticalSpeed = verticalInput * verticalLimit
        local currentVerticalSpeed = state.velocity.Y
        local verticalRate = math.abs(targetVerticalSpeed) > math.abs(currentVerticalSpeed)
            and config.movement.acceleration
            or config.movement.deceleration
        local verticalSpeed = approach(currentVerticalSpeed, targetVerticalSpeed, verticalRate * dt)

        state.velocity = forward * forwardSpeed
            + right * sidewaysSpeed
            + Vector3.yAxis * verticalSpeed
        state.targetVelocity = state.velocity
        state.currentSpeed = state.velocity.Magnitude
        state.hoverAnchorPosition = nil
        state.hoverTargetPosition = nil
        state.hoverTime = 0
        state.hoverVisualOffset = Vector3.zero
    elseif returningToHover then
        local returnSpeed = approach(state.velocity.Magnitude, 0, config.movement.deceleration * dt)
        state.velocity = returnSpeed > 0.1 and state.velocity.Unit * returnSpeed or Vector3.zero
        state.targetVelocity = state.velocity
        state.currentSpeed = state.velocity.Magnitude
        state.hoverVisualOffset = Vector3.zero
    else
        state.velocity = Vector3.zero
        state.targetVelocity = Vector3.zero
        state.currentSpeed = 0
        state.hoverAnchorPosition = state.hoverAnchorPosition or basePivot.Position
        state.hoverTime += dt
        state.hoverVisualOffset = Vector3.new(
            0,
            math.sin(state.hoverTime * config.movement.hoverBobSpeed)
                * config.movement.hoverBobHeight,
            0
        )
    end

    local targetPitch = 0
    local pitchResponse = math.abs(pitchInput) > 0.01
        and config.roll.responseSpeed
        or config.roll.recoverySpeed
    state.pitch = approach(state.pitch, targetPitch, pitchResponse * dt)

    local targetRoll = rollInput * config.movement.maximumRollAngle
    local rollResponse = math.abs(rollInput) > 0.01
        and config.roll.responseSpeed
        or config.roll.recoverySpeed
    state.roll = approach(state.roll, targetRoll, rollResponse * dt)

    local horizontalSpeed = math.sqrt(
        forwardSpeed * forwardSpeed
            + sidewaysSpeed * sidewaysSpeed
    )
    local speedFactor = math.clamp(
        horizontalSpeed / math.max(config.movement.normalSpeed, 1),
        0,
        1
    )
    local bankTurn = math.sin(math.rad(state.roll))
        * math.rad(config.movement.bankTurnRate)
        * speedFactor
    local rudderTurn = rudderInput * math.rad(18)
    local yaw = (bankTurn + rudderTurn) * dt
    local physicalOrientation = getPhysicalOrientation(state.orientation)
    local flatLook = Vector3.new(
        physicalOrientation.LookVector.X,
        0,
        physicalOrientation.LookVector.Z
    )
    if flatLook.Magnitude < 0.001 then
        flatLook = Vector3.zAxis
    else
        flatLook = flatLook.Unit
    end
    local nextPhysicalOrientation = CFrame.new(Vector3.zero, flatLook)
        * CFrame.Angles(0, yaw, 0)
    state.targetOrientation = nextPhysicalOrientation * config.modelForwardCorrection:Inverse()
    state.orientation = state.targetOrientation

    local desiredPosition = basePivot.Position + state.velocity * dt
    if not hasFlightInput and not returningToHover and state.hoverAnchorPosition then
        desiredPosition = state.hoverAnchorPosition + state.hoverVisualOffset
    end

    local nextPosition = limitPosition(player, desiredPosition, state.origin)
    nextPosition = limitCollisionPosition(player, drone, nextPosition, basePivot.Position)
    nextPosition = limitVerticalPosition(player, drone, nextPosition, basePivot.Position)

    if not hasFlightInput and not returningToHover then
        state.hoverAnchorPosition = nextPosition - state.hoverVisualOffset
    end

    state.targetPosition = nextPosition
    drone:SetAttribute("TargetPosition", state.targetPosition)
    drone:SetAttribute("TargetVelocity", state.targetVelocity)
    drone:SetAttribute("TargetOrientation", state.targetOrientation)
    drone:SetAttribute("CurrentSpeed", state.currentSpeed)
    drone:SetAttribute("SpeedSetting", state.speedSetting)
    drone:SetAttribute("CurrentRoll", state.roll)
    drone:SetAttribute("CurrentPitch", state.pitch)
    drone:PivotTo(
        CFrame.new(state.targetPosition)
            * state.targetOrientation
            * CFrame.Angles(math.rad(state.pitch), 0, math.rad(-state.roll))
    )

    local droneCamera = drone:FindFirstChild("FPVCamera", true)
    if droneCamera and droneCamera:IsA("Camera") and drone.PrimaryPart then
        local root = drone.PrimaryPart
        local forward = (root.CFrame * config.DroneModelOrientationOffset).LookVector
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

        local cameraPosition = root.Position + forward * (frontExtent + 0.5) + up * 0.15
        droneCamera.CFrame = CFrame.lookAt(
            cameraPosition,
            cameraPosition + forward,
            up
        )
        droneCamera.FieldOfView = config.camera.fpvFov
        drone:SetAttribute("FPVCameraCFrame", droneCamera.CFrame)
        drone:SetAttribute("FPVCameraFov", droneCamera.FieldOfView)
    end

    if state.propellerMotor and state.propellerMotor.Parent then
        local speedRatio = math.clamp(
            state.currentSpeed / math.max(config.movement.normalSpeed, 1),
            0.35,
            1.4
        )
        state.propellerAngle = (
            state.propellerAngle
            + config.propeller.rotationSpeed * speedRatio * dt
        ) % (math.pi * 2)
        state.propellerMotor.Transform = CFrame.Angles(0, 0, state.propellerAngle)
    end

    drone.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
    drone.PrimaryPart.AssemblyAngularVelocity = Vector3.zero
end

function movementService:Init()
    inputEvent.OnServerEvent:Connect(function(player, value)
        local now = os.clock()
        local state = states[player]
        if state and now - state.lastInput < inputDelay then
            return
        end

        local drone = getDrone(player)
        local input = readInput(value)
        if player:GetAttribute("DroneSessionState") ~= "ControllingDrone"
            or not hasEquippedRemote(player)
            or not drone
            or not input then
            return
        end

        local current = getState(player, drone)
        current.input = input
        current.lastInput = now
    end)
end

function movementService:Start()
    RunService.Heartbeat:Connect(function(dt)
        local folder = Workspace:FindFirstChild("ActiveDrones")
        if folder then
            for _, player in ipairs(Players:GetPlayers()) do
                local drone = folder:FindFirstChild(player.Name .. "_Drone")
                if drone and drone:IsA("Model") and drone.PrimaryPart
                    and drone:GetAttribute("ControlsEnabled") == true then
                    local state = getState(player, drone)
                    updateDrone(player, state, dt)
                else
                    states[player] = nil
                end
            end
        end
    end)

    Players.PlayerRemoving:Connect(function(player)
        states[player] = nil
    end)
end

return movementService

