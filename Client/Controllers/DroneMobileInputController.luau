--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local states = require(ReplicatedStorage.Shared.Drone.DroneStates)
local inputState = require(ReplicatedStorage.Shared.Drone.DroneInputState)
local stateEvent = ReplicatedStorage.Remotes:WaitForChild("DroneStateChanged")

local controller = {}
local connections: {RBXScriptConnection} = {}
local gui: ScreenGui?
local active = false
local started = false


local function setValue(name: string, value: number)
    if active then
        inputState:Set(name, value)
    else
        inputState:Clear()
    end
end

local function clear()
    inputState:Clear()
end

local function makeButton(parent: GuiObject, name: string, text: string, position: UDim2, size: UDim2, field: string, value: number)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Text = text
    button.TextScaled = true
    button.BackgroundTransparency = 0.25
    button.BackgroundColor3 = Color3.fromRGB(25, 30, 38)
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Position = position
    button.Size = size
    button.Parent = parent

    table.insert(connections, button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            setValue(field, value)
        end
    end))

    table.insert(connections, button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            setValue(field, 0)
        end
    end))
end

local function build()
    if gui or not UserInputService.TouchEnabled then
        return
    end

    gui = Instance.new("ScreenGui")
    gui.Name = "DroneMobileControls"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.Parent = player:WaitForChild("PlayerGui")

    local left = Instance.new("Frame")
    left.Name = "Movement"
    left.BackgroundTransparency = 1
    left.Position = UDim2.fromScale(0.03, 0.65)
    left.Size = UDim2.fromScale(0.3, 0.3)
    left.Parent = gui

    local right = Instance.new("Frame")
    right.Name = "Flight"
    right.BackgroundTransparency = 1
    right.Position = UDim2.fromScale(0.67, 0.55)
    right.Size = UDim2.fromScale(0.3, 0.4)
    right.Parent = gui

    local buttonSize = UDim2.fromScale(0.28, 0.24)
    makeButton(left, "Forward", "▲", UDim2.fromScale(0.36, 0), buttonSize, "forward", 1)
    makeButton(left, "Back", "▼", UDim2.fromScale(0.36, 0.52), buttonSize, "forward", -1)
    makeButton(left, "Left", "◀", UDim2.fromScale(0.05, 0.26), buttonSize, "sideways", -1)
    makeButton(left, "Right", "▶", UDim2.fromScale(0.67, 0.26), buttonSize, "sideways", 1)

    makeButton(right, "SpeedUp", "+", UDim2.fromScale(0.05, 0), buttonSize, "speed", 1)
    makeButton(right, "SpeedDown", "−", UDim2.fromScale(0.37, 0), buttonSize, "speed", -1)
    makeButton(right, "RollLeft", "↶", UDim2.fromScale(0.05, 0.52), buttonSize, "roll", -1)
    makeButton(right, "RollRight", "↷", UDim2.fromScale(0.37, 0.52), buttonSize, "roll", 1)
end

function controller:Init()
    build()
end

function controller:Start()
    if started then
        return
    end

    started = true

    table.insert(connections, stateEvent.OnClientEvent:Connect(function(nextState)
        nextState = type(nextState) == "table" and nextState.state or nextState
        active = nextState == states.ControllingDrone
        if not active then
            clear()
            if gui then
                gui.Enabled = false
            end
        elseif gui then
            gui.Enabled = true
        end
    end))

    table.insert(connections, player.CharacterRemoving:Connect(function()
        clear()
        active = false
    end))
end

return controller

