--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local states = require(ReplicatedStorage.Shared.Drone.DroneStates)
local animationData = require(ReplicatedStorage.Shared.Drone.DroneAnimations)
local animationController = require(script.Parent.DroneAnimationController)
local mobileInput = require(ReplicatedStorage.Shared.Drone.DroneInputState)

local inputEvent = ReplicatedStorage.Remotes:WaitForChild("DroneInput")
local stateEvent = ReplicatedStorage.Remotes:WaitForChild("DroneStateChanged")

local controller = {}

local connections: {RBXScriptConnection} = {}
local boundActions: {string} = {}
local actionsBound = false
local joystickRenderStepName = "DroneJoystickPose_" .. tostring(player.UserId)
local characterAddedConnection: RBXScriptConnection?
local testEvent: BindableEvent?
local testConnection: RBXScriptConnection?

local pressed: {[string]: boolean} = {}
local leftStick = Vector2.zero
local rightStick = Vector2.zero
local active = false
local started = false
local lastSent = 0
local lastInput = ""
local lastAction = "none"
local traceKey = ""

local actionAnimations = {
    forward = {"joystickLeftForward", animationData.leftStickForward},
    backward = {"joystickLeftBackward", animationData.leftStickBackward},
    left = {"joystickLeftLeft", animationData.leftStickLeft},
    right = {"joystickLeftRight", animationData.leftStickRight},
    verticalUp = {"joystickRightForward", animationData.rightStickForward},
    verticalDown = {"joystickRightBackward", animationData.rightStickBackward},
    rollLeft = {"joystickRightLeft", animationData.rightStickLeft},
    rollRight = {"joystickRightRight", animationData.rightStickRight},
}
local joystickTransforms: {[string]: CFrame} = {}
local joystickBaseC0: {[string]: CFrame} = {}
local visibleJoystickBaseC0: {[string]: CFrame} = {}
local lastJoystickRemote: Model?
local lastVisibleRemote: Model?

local neutralInput = {
    forward = 0,
    sideways = 0,
    vertical = 0,
    speed = 0,
    roll = 0,
    yaw = 0,
}

local function addConnection(connection: RBXScriptConnection)
    table.insert(connections, connection)
end

local function isDown(action: string): number
    return pressed[action] and 1 or 0
end

local function getMovement()
    local mobile = mobileInput:Get()
    local keyboardForward = isDown("forward") - isDown("backward")
    local keyboardSideways = isDown("right") - isDown("left")
    local keyboardVertical = isDown("verticalUp") - isDown("verticalDown")
    local keyboardSpeed = isDown("speedUp") - isDown("slowDown")
    local keyboardRoll = isDown("rollRight") - isDown("rollLeft")
    local keyboardYaw = isDown("yawRight") - isDown("yawLeft")

    local forward = math.abs(leftStick.Y) > 0.1
        and leftStick.Y
        or mobile.forward ~= 0 and mobile.forward or keyboardForward
    local sideways = math.abs(leftStick.X) > 0.1
        and leftStick.X
        or mobile.sideways ~= 0 and mobile.sideways or keyboardSideways
    local vertical = mobile.vertical ~= 0 and mobile.vertical or keyboardVertical
    local speed = math.abs(rightStick.Y) > 0.1
        and rightStick.Y
        or mobile.speed ~= 0 and mobile.speed or keyboardSpeed
    local roll = math.abs(rightStick.X) > 0.1
        and rightStick.X
        or mobile.roll ~= 0 and mobile.roll or keyboardRoll

    return {
        forward = math.clamp(forward, -1, 1),
        sideways = math.clamp(sideways, -1, 1),
        vertical = math.clamp(vertical, -1, 1),
        speed = math.clamp(speed, -1, 1),
        roll = math.clamp(roll, -1, 1),
        yaw = math.clamp(keyboardYaw, -1, 1),
    }
end

local function traceJoystickInput(movement)
    if not RunService:IsStudio() then
        return
    end

    local leftName = movement.forward > 0.1 and "joystickLeftForward"
        or movement.forward < -0.1 and "joystickLeftBackward"
        or movement.sideways < -0.1 and "joystickLeftLeft"
        or movement.sideways > 0.1 and "joystickLeftRight"
        or "none"
    local rightName = movement.speed > 0.1 and "joystickRightForward"
        or movement.speed < -0.1 and "joystickRightBackward"
        or movement.roll < -0.1 and "joystickRightLeft"
        or movement.roll > 0.1 and "joystickRightRight"
        or "none"
    local key = table.concat({lastAction, leftName, rightName, tostring(leftStick), tostring(rightStick)}, "|")
    if key == traceKey then
        return
    end
    traceKey = key
    player:SetAttribute("StickTraceLabel", lastAction)

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    print(("[StickTrace] action=%s state=%s session=%s left=(%.2f,%.2f) right=(%.2f,%.2f) leftSelected=%s rightSelected=%s animator=%s")
        :format(lastAction, tostring(player:GetAttribute("DroneClientState")), tostring(player:GetAttribute("DroneClientSessionId")),
            leftStick.X, leftStick.Y, rightStick.X, rightStick.Y, leftName, rightName,
            animator and animator:GetFullName() or "none"))

    if animator then
        for _, name in ipairs({leftName, rightName}) do
            if name ~= "none" then
                local info = animationData[name == "joystickLeftForward" and "leftStickForward"
                    or name == "joystickLeftBackward" and "leftStickBackward"
                    or name == "joystickLeftLeft" and "leftStickLeft"
                    or name == "joystickLeftRight" and "leftStickRight"
                    or name == "joystickRightForward" and "rightStickForward"
                    or name == "joystickRightBackward" and "rightStickBackward"
                    or name == "joystickRightLeft" and "rightStickLeft"
                    or "rightStickRight"]
                local track
                for _, playing in ipairs(animator:GetPlayingAnimationTracks()) do
                    if playing.Name == name then
                        track = playing
                        break
                    end
                end
                print(("[StickTrace] selected=%s id=%s playing=%s time=%.3f weight=%.2f priority=%s")
                    :format(name, tostring(info and info.animationId), tostring(track and track.IsPlaying or false),
                        track and track.TimePosition or -1, track and track.WeightCurrent or 0,
                        track and track.Priority.Name or "none"))
            end
        end

        local remote = character and character:FindFirstChild("HeldRemote")
        if remote then
            for _, object in ipairs(remote:GetDescendants()) do
                if object:IsA("Motor6D") and (object.Name == "Left Stick" or object.Name == "Right Stick") then
                    local part = object.Part1
                    print(("[StickTrace] joint=%s name=%s part0=%s part1=%s transform=%s part1Orientation=%s")
                        :format(object:GetFullName(), object.Name, object.Part0 and object.Part0.Name or "nil",
                            part and part.Name or "nil", tostring(object.Transform),
                            part and tostring(part.Orientation) or "nil"))
                end
            end
        end
    end
end

local function updatePhysicalJoysticks(movement, dt: number)
    local character = player.Character
    local remote = character and character:FindFirstChild("HeldRemote")
    local bodyAttach = remote and remote:FindFirstChild("BodyAttach")
    if not bodyAttach or not bodyAttach:IsA("BasePart") then
        table.clear(joystickTransforms)
        table.clear(joystickBaseC0)
        lastJoystickRemote = nil
        return
    end

    if remote ~= lastJoystickRemote then
        table.clear(joystickTransforms)
        table.clear(joystickBaseC0)
        lastJoystickRemote = remote
    end

    local forwardAngle = config.joystick.maximumAngle
    local sidewaysAngle = config.joystick.sidewaysAngle
    local neutralCorrection = CFrame.identity
    local leftVertical = movement.forward
    local leftHorizontal = movement.sideways
    local rightVertical = math.abs(movement.vertical) > 0.01 and movement.vertical or movement.speed
    local rightHorizontal = movement.roll
    local targets = {
        ["Left Stick"] = neutralCorrection * CFrame.Angles(
            -leftVertical * forwardAngle,
            leftHorizontal * sidewaysAngle,
            0
        ),
        ["Right Stick"] = neutralCorrection * CFrame.Angles(
            -rightVertical * forwardAngle,
            rightHorizontal * sidewaysAngle,
            0
        ),
    }

    for name, target in pairs(targets) do
        local motor = bodyAttach:FindFirstChild(name)
        if motor and motor:IsA("Motor6D") then
            local baseC0 = joystickBaseC0[name] or motor.C0
            joystickBaseC0[name] = baseC0

            local current = joystickTransforms[name] or CFrame.identity
            local moving = target ~= CFrame.identity
            local response = moving and config.joystick.responseSpeed or config.joystick.returnSpeed
            local blend = 1 - math.exp(-response * dt)
            current = current:Lerp(target, blend)
            motor.C0 = baseC0 * current
            motor.Transform = CFrame.identity
            joystickTransforms[name] = current
        end
    end

    local visibleRemote = character and character:FindFirstChild("Remote")
    local visibleRoot = visibleRemote and visibleRemote:FindFirstChild("RemoteRoot", true)
    if visibleRemote ~= lastVisibleRemote then
        table.clear(visibleJoystickBaseC0)
        lastVisibleRemote = visibleRemote
    end
    if visibleRoot then
        for name, current in pairs(joystickTransforms) do
            local motor = visibleRoot:FindFirstChild(name)
            if motor and motor:IsA("Motor6D") then
                local baseC0 = visibleJoystickBaseC0[name] or motor.C0
                visibleJoystickBaseC0[name] = baseC0
                motor.C0 = baseC0 * current
                motor.Transform = CFrame.identity
            end
        end
    end
end

local updateJoystickAnimations

local function sendNeutral()
    lastInput = ""
    lastSent = os.clock()
    inputEvent:FireServer(neutralInput)
end

updateJoystickAnimations = function(movement)
    local function setJoystick(name, info, amount)
        local magnitude = math.clamp(amount, 0, 1)
        if magnitude <= 0.1 then
            animationController:StopJoystick(name)
        else
            animationController:PlayJoystick(name, info)
        end
    end

    setJoystick("joystickLeftForward", animationData.leftStickForward, movement.forward)
    setJoystick("joystickLeftBackward", animationData.leftStickBackward, -movement.forward)
    setJoystick("joystickLeftLeft", animationData.leftStickLeft, -movement.sideways)
    setJoystick("joystickLeftRight", animationData.leftStickRight, movement.sideways)

    local rightVertical = math.abs(movement.vertical) > 0.01 and movement.vertical or movement.speed
    setJoystick("joystickRightForward", animationData.rightStickForward, rightVertical)
    setJoystick("joystickRightBackward", animationData.rightStickBackward, -rightVertical)
    setJoystick("joystickRightLeft", animationData.rightStickLeft, -movement.roll)
    setJoystick("joystickRightRight", animationData.rightStickRight, movement.roll)
end

local function sendInput(force: boolean?)
    if not active then
        return
    end

    local movement = getMovement()
    local inputKey = table.concat({
        string.format("%.2f", movement.forward),
        string.format("%.2f", movement.sideways),
        string.format("%.2f", movement.vertical),
        string.format("%.2f", movement.speed),
        string.format("%.2f", movement.roll),
        string.format("%.2f", movement.yaw),
    }, ",")

    local now = os.clock()
    if not force and inputKey == lastInput and now - lastSent < config.inputSendRate then
        return
    end

    lastInput = inputKey
    lastSent = now
    inputEvent:FireServer(movement)
    traceJoystickInput(movement)
end

local function handleDigital(actionName: string, inputState: Enum.UserInputState)
    if not active then
        return Enum.ContextActionResult.Pass
    end

    lastAction = actionName .. ":" .. inputState.Name
    if inputState == Enum.UserInputState.Begin then
        pressed[actionName] = true
        local animation = actionAnimations[actionName]
        if animation then
            animationController:PlayJoystick(animation[1], animation[2])
        end
    elseif inputState == Enum.UserInputState.End then
        pressed[actionName] = nil
        local animation = actionAnimations[actionName]
        if animation then
            animationController:StopJoystick(animation[1])
        end
    end

    sendInput(true)
    return Enum.ContextActionResult.Sink
end

local function processStick(
    actionName: string,
    inputState: Enum.UserInputState,
    value: Vector2
)
    if not active then
        return Enum.ContextActionResult.Pass
    end

    lastAction = actionName .. ":" .. inputState.Name
    if inputState == Enum.UserInputState.Change then
        if actionName == "leftStick" then
            leftStick = value
        else
            rightStick = value
        end
    elseif inputState == Enum.UserInputState.End then
        if actionName == "leftStick" then
            leftStick = Vector2.zero
        else
            rightStick = Vector2.zero
        end
    end

    sendInput(true)
    updateJoystickAnimations(getMovement())
    return Enum.ContextActionResult.Sink
end

local function handleStick(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
    local value = Vector2.new(inputObject.Position.X, -inputObject.Position.Y)
    return processStick(actionName, inputState, value)
end

local function bindAction(name: string, callback, ...)
    ContextActionService:BindActionAtPriority(
        name,
        callback,
        false,
        Enum.ContextActionPriority.High.Value,
        ...
    )
    table.insert(boundActions, name)
end

local function unbindActions()
    if not actionsBound then
        return
    end

    for _, name in ipairs(boundActions) do
        ContextActionService:UnbindAction(name)
    end
    table.clear(boundActions)
    actionsBound = false
end

local function bindActions()
    if actionsBound then
        return
    end

    bindAction("forward", handleDigital, config.input.forward)
    bindAction("backward", handleDigital, config.input.backward)
    bindAction("left", handleDigital, config.input.left)
    bindAction("right", handleDigital, config.input.right)
    bindAction("rollLeft", handleDigital, config.input.rollLeft)
    bindAction("rollRight", handleDigital, config.input.rollRight)
    bindAction("verticalUp", handleDigital, config.input.verticalUp, Enum.KeyCode.ButtonR2)
    bindAction("verticalDown", handleDigital, config.input.verticalDown, Enum.KeyCode.ButtonL2)
    bindAction("yawLeft", handleDigital, Enum.KeyCode.ButtonL1)
    bindAction("yawRight", handleDigital, Enum.KeyCode.ButtonR1)
    bindAction("leftStick", handleStick, Enum.KeyCode.Thumbstick1)
    bindAction("rightStick", handleStick, Enum.KeyCode.Thumbstick2)
    actionsBound = true
end

local function clearInput()
    table.clear(pressed)
    leftStick = Vector2.zero
    rightStick = Vector2.zero
    mobileInput:Clear()
    sendNeutral()

    if player:GetAttribute("DroneClientState") ~= states.ControllingDrone then
        animationController:StopRemote()
    end
end

local function clearTestHarness()
    if testConnection then
        testConnection:Disconnect()
        testConnection = nil
    end

    if testEvent then
        testEvent:Destroy()
        testEvent = nil
    end
end

local function setupTestHarness()
    if not RunService:IsStudio() then
        return
    end

    clearTestHarness()

    local event = Instance.new("BindableEvent")
    event.Name = "DroneJoystickTest"
    event.Parent = player:WaitForChild("PlayerScripts")
    testEvent = event
    testConnection = event.Event:Connect(function(actionName, inputState, value)
        if actionName == "leftStick" or actionName == "rightStick" then
            if typeof(value) ~= "Vector2" then
                value = Vector2.zero
            end

            processStick(actionName, inputState, value)
        elseif actionName == "forward"
            or actionName == "backward"
            or actionName == "left"
            or actionName == "right"
            or actionName == "speedUp"
            or actionName == "slowDown"
            or actionName == "rollLeft"
            or actionName == "rollRight"
            or actionName == "verticalUp"
            or actionName == "verticalDown" then
            handleDigital(actionName, inputState)
        end
    end)
end

local function stop()
    clearInput()
    active = false
    unbindActions()
    clearTestHarness()

    RunService:UnbindFromRenderStep(joystickRenderStepName)

    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end

    table.clear(connections)
    started = false
end

function controller:Init()
end

function controller:Start()
    if started then
        return
    end

    started = true
    setupTestHarness()

    if RunService:IsStudio() then
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if animator then
            addConnection(animator.AnimationPlayed:Connect(function(track)
                if string.sub(track.Name, 1, 8) == "joystick" then
                    print(("[StickTrace] AnimationPlayed name=%s id=%s animator=%s")
                        :format(track.Name, track.Animation and track.Animation.AnimationId or "nil", animator:GetFullName()))
                end
            end))
        end
    end

    addConnection(stateEvent.OnClientEvent:Connect(function(nextState)
        nextState = type(nextState) == "table" and nextState.state or nextState

        local currentClientState = player:GetAttribute("DroneClientState")
        if currentClientState == states.ControllingDrone
            and nextState ~= states.ControllingDrone then
            return
        end

        if nextState == states.ControllingDrone then
            active = true
            bindActions()
            sendInput(true)
        elseif nextState == states.RemoteIdle
            or nextState == states.EnteringFPV
            or nextState == states.ExitingDrone
            or nextState == states.Unequipped then
            clearInput()
            active = false
            unbindActions()
        end
    end))

    addConnection(RunService.Heartbeat:Connect(function()
        sendInput(false)
    end))

    RunService:BindToRenderStep(
        joystickRenderStepName,
        Enum.RenderPriority.Last.Value + 1,
        function(dt)
            updatePhysicalJoysticks(active and getMovement() or neutralInput, dt)
        end
    )

    local character = player.Character
    if character then
        addConnection(character.ChildRemoved:Connect(function(child)
            if child:IsA("Tool") and child.Name == "Remote" then
                clearInput()
                active = false
                unbindActions()
            end
        end))
    end

    if not characterAddedConnection then
        characterAddedConnection = player.CharacterAdded:Connect(function()
            task.defer(function()
                controller:Start()
            end)
        end)
    end

    addConnection(player.CharacterRemoving:Connect(function()
        stop()
    end))
end

function controller:SetActive(value: boolean)
    if value then
        active = true
        bindActions()
        sendInput(true)
    else
        clearInput()
        active = false
        unbindActions()
    end
end

function controller:GetMovement()
    return getMovement()
end

return controller

