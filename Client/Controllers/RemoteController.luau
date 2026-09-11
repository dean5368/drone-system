--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local player = Players.LocalPlayer
local controller = {}

local remoteModel: Model?
local remoteWeld: JointInstance?
local handTrackingConnection: RBXScriptConnection?
local remoteVisibilityBound = false
local remoteVisibilityBindName = "RemoteVisibility_" .. tostring(player.UserId)
local rightArmIK: IKControl?
local rightArmIKTarget: BasePart?
local rightArmIKOffset: CFrame?
local leftArmIK: IKControl?
local leftArmIKTarget: BasePart?
local leftElbowTarget: BasePart?
local leftGripAttachment: Attachment?
local leftHandGripOffset: CFrame?
local leftGrip: Attachment?
local rightGrip: Attachment?
local ikBlendRequested = false
local ikWeight = 0
local createCount = 0

local function clearRemote()
    if remoteVisibilityBound then
        RunService:UnbindFromRenderStep(remoteVisibilityBindName)
        remoteVisibilityBound = false
    end

    if handTrackingConnection then
        handTrackingConnection:Disconnect()
        handTrackingConnection = nil
    end

    if rightArmIK then
        rightArmIK.Weight = 0
        rightArmIK.Enabled = false
        rightArmIK:Destroy()
        rightArmIK = nil
    end

    if rightArmIKTarget then
        rightArmIKTarget:Destroy()
        rightArmIKTarget = nil
    end

    rightArmIKOffset = nil

    if leftArmIK then
        leftArmIK.Weight = 0
        leftArmIK.Enabled = false
        leftArmIK:Destroy()
        leftArmIK = nil
    end

    if leftArmIKTarget then
        leftArmIKTarget:Destroy()
        leftArmIKTarget = nil
    end

    if leftElbowTarget then
        leftElbowTarget:Destroy()
        leftElbowTarget = nil
    end

    leftGripAttachment = nil
    leftHandGripOffset = nil
    ikBlendRequested = false
    ikWeight = 0

    if remoteWeld then
        remoteWeld:Destroy()
        remoteWeld = nil
    end

    if remoteModel then
        remoteModel:Destroy()
        remoteModel = nil
    end
end

local function getWorldCFrame(object: Instance): CFrame?
    if object:IsA("Attachment") then
        return object.WorldCFrame
    end

    if object:IsA("BasePart") then
        return object.CFrame
    end

    return nil
end

local function createTargetPart(name: string, targetCFrame: CFrame): BasePart
    local part = Instance.new("Part")
    part.Name = name
    part.Size = Vector3.new(0.1, 0.1, 0.1)
    part.Transparency = 1
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CFrame = targetCFrame
    part.Parent = Workspace
    return part
end







local function bindRemoteVisibility()
    if remoteVisibilityBound then
        return
    end

    RunService:BindToRenderStep(
        remoteVisibilityBindName,
        Enum.RenderPriority.Last.Value,
        function()
            local model = remoteModel
            if not model or not model.Parent then
                return
            end

            for _, object in ipairs(model:GetDescendants()) do
                if object:IsA("BasePart") then
                    object.LocalTransparencyModifier = 0
                end
            end
        end
    )
    remoteVisibilityBound = true
end

local function findTool(createIfMissing: boolean?): Tool?
    local character = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")
    local tool = character and character:FindFirstChild("Remote")
        or backpack and backpack:FindFirstChild("Remote")

    if createIfMissing and not tool and backpack then
        local template = ReplicatedStorage:FindFirstChild("Remote")
        if template and template:IsA("Tool") then
            tool = template:Clone()
            tool.Parent = backpack
        end
    end

    return tool and tool:IsA("Tool") and tool or nil
end

local function removeExternalJoints(model: Model)
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("JointInstance")
            and (not object.Part0
                or not object.Part1
                or not object.Part0:IsDescendantOf(model)
                or not object.Part1:IsDescendantOf(model)) then
            object:Destroy()
        end
    end
end

local function removeStickRootJoints(root: BasePart)
    for _, object in ipairs(root:GetChildren()) do
        if (object:IsA("Weld") or object:IsA("WeldConstraint"))
            and object.Part1
            and (object.Part1.Name == "Left Stick" or object.Part1.Name == "Right Stick") then
            object:Destroy()
        end
    end
end

local function ensureScreenWeld(root: BasePart, screen: BasePart)
    local validWeld
    for _, object in ipairs(root:GetChildren()) do
        if object.Name == "RemoteScreenWeld" then
            local valid = object:IsA("WeldConstraint")
                and ((object.Part0 == root and object.Part1 == screen)
                    or (object.Part0 == screen and object.Part1 == root))
            if valid and not validWeld then
                validWeld = object
            else
                object:Destroy()
            end
        end
    end

    if validWeld then
        return
    end

    local weld = Instance.new("WeldConstraint")
    weld.Name = "RemoteScreenWeld"
    weld.Part0 = root
    weld.Part1 = screen
    weld.Parent = root
end

local function addCanonicalScreen(model: Model, root: BasePart)
    local existingScreen = model:FindFirstChild("FPVScreen", true)
    if existingScreen and existingScreen:IsA("BasePart") then
        ensureScreenWeld(root, existingScreen)
        return
    end

    local sourceTool = ReplicatedStorage:FindFirstChild("Remote")
    local sourceModel = sourceTool and sourceTool:FindFirstChild("RemoteModel")
    local sourceRoot = sourceModel and sourceModel:FindFirstChild("RemoteRoot", true)
    local sourceScreen = sourceModel and sourceModel:FindFirstChild("FPVScreen", true)

    if not sourceModel or not sourceRoot or not sourceRoot:IsA("BasePart")
        or not sourceScreen or not sourceScreen:IsA("BasePart") then
        return
    end

    local screen = sourceScreen:Clone()
    screen.CFrame = root.CFrame * sourceRoot.CFrame:ToObjectSpace(sourceScreen.CFrame)
    screen.Parent = model
    ensureScreenWeld(root, screen)
end

local function alignScreenOverlay(model: Model)
    local screen = model:FindFirstChild("FPVScreen", true)
    if not screen or not screen:IsA("BasePart") then
        return
    end

    local display: BasePart?
    local displayArea = 0
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") and object ~= screen then
            local size = object.Size
            local thin = math.min(size.X, size.Y, size.Z)
            local wide = math.max(size.X, size.Y, size.Z)
            local area = size.X * size.Y * size.Z
            if thin < 0.08 and wide > 0.5 and area > displayArea then
                display = object
                displayArea = area
            end
        end
    end

    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") and object.Name == "Cube.057" then
            display = object
            break
        end
    end

    if not display then
        return
    end

    local size = display.Size
    if size.X <= size.Y and size.X <= size.Z then
        screen.Size = size + Vector3.new(0.01, 0.01, 0.01)
        screen.CFrame = display.CFrame
    elseif size.Y <= size.X and size.Y <= size.Z then
        screen.Size = Vector3.new(size.X, size.Z, math.max(size.Y, 0.01))
        screen.CFrame = CFrame.lookAt(display.Position, display.Position - display.CFrame.UpVector, display.CFrame.LookVector)
    else
        screen.Size = Vector3.new(size.X, size.Y, math.max(size.Z, 0.01))
        screen.CFrame = display.CFrame
    end

    screen.Transparency = 1
end

local function centerScreenTarget(model: Model)
    local screen = model:FindFirstChild("FPVScreen", true)
    local target = screen and screen:FindFirstChild("FPVScreenTarget")
    if screen and screen:IsA("BasePart")
        and target and target:IsA("Attachment") then
        local frontOffset = math.max(screen.Size.Z * 0.5 + 0.02, 0.02)
        target.CFrame = CFrame.new(0, 0, -frontOffset) * target.CFrame.Rotation
    end
end

local function attachNativeRemote(model: Model, root: BasePart, upperTorso: BasePart)
    local targetCFrame = upperTorso.CFrame
        * CFrame.new(0.03, 0.15, -1.35)

    model:PivotTo(targetCFrame)

    local bodyAttach = model:FindFirstChild("BodyAttach")
    if bodyAttach then
        bodyAttach:Destroy()
    end

    bodyAttach = Instance.new("Part")
    bodyAttach.Name = "BodyAttach"
    bodyAttach.Size = Vector3.new(0.4, 0.4, 0.4)
    bodyAttach.Transparency = 1
    bodyAttach.CanCollide = false
    bodyAttach.CanTouch = false
    bodyAttach.CanQuery = false
    bodyAttach.Massless = true
    bodyAttach.CFrame = root.CFrame
    bodyAttach.Parent = model

    local rootConnection = Instance.new("WeldConstraint")
    rootConnection.Name = "RemoteRootConnection"
    rootConnection.Part0 = bodyAttach
    rootConnection.Part1 = root
    rootConnection.Parent = bodyAttach

    for _, joint in ipairs(root:GetChildren()) do
        if joint:IsA("Motor6D") and joint.Part1 then
            local part1 = joint.Part1
            local c1 = joint.C1
            local c0 = bodyAttach.CFrame:ToObjectSpace(part1.CFrame) * c1
            joint.Part0 = bodyAttach
            joint.C0 = c0
            joint.Parent = bodyAttach
        end
    end

    local motor = Instance.new("Motor6D")
    motor.Name = "Motor6D"
    motor.Part0 = upperTorso
    motor.Part1 = bodyAttach

    local idleStart = CFrame.new(0.057, 0.05, -1.648)
        * CFrame.Angles(
            math.rad(-12),
            math.rad(0),
            math.rad(0)
        )
    motor.C0 = upperTorso.CFrame:ToObjectSpace(bodyAttach.CFrame) * idleStart:Inverse()
    motor.C1 = CFrame.identity
    motor.Parent = model

    return motor
end

function controller:Create(): boolean
    if remoteModel and remoteModel.Parent then
        return true
    end

    clearRemote()

    local character = player.Character
    local hand = character and character:FindFirstChild("RightHand")
    local tool = findTool(true)
    local template = tool and tool:FindFirstChild("RemoteModel")

    if not character or not hand or not hand:IsA("BasePart") then
        warn("[RemoteController] RightHand was not found")
        return false
    end

    if not template or not template:IsA("Model") then
        warn("[RemoteController] RemoteModel template was not found")
        return false
    end

    local model = template:Clone()
    model.Name = "HeldRemote"

    local root = model.PrimaryPart or model:FindFirstChild("RemoteRoot", true)
    if not root or not root:IsA("BasePart") then
        model:Destroy()
        warn("[RemoteController] RemoteRoot was not found")
        return false
    end

    model.PrimaryPart = root
    removeExternalJoints(model)
    removeStickRootJoints(root)
    addCanonicalScreen(model, root)

    local screen = model:FindFirstChild("FPVScreen", true)
    local screenWeld = root:FindFirstChild("RemoteScreenWeld")
    if screenWeld then
        screenWeld:Destroy()
    end

    alignScreenOverlay(model)

    if screen and screen:IsA("BasePart") then
        ensureScreenWeld(root, screen)
    end

    centerScreenTarget(model)



    for _, object in ipairs(template:GetDescendants()) do
        if object:IsA("BasePart") then
            object.LocalTransparencyModifier = 1
        end
    end

    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") then
            object.Anchored = false
            object.Massless = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.LocalTransparencyModifier = 0
        end
    end

    

    local screen = model:FindFirstChild("FPVScreen", true)
    local screenTarget = screen and screen:FindFirstChild("FPVScreenTarget")
    if screen and screen:IsA("BasePart")
        and screenTarget and screenTarget:IsA("Attachment")
        and not screen:FindFirstChild("FPVScreenFocus") then
        local focus = Instance.new("Attachment")
        focus.Name = "FPVScreenFocus"
        focus.CFrame = screenTarget.CFrame
        focus.Parent = screen
    end

    model.Parent = character
    local upperTorso = character:FindFirstChild("UpperTorso")
    if not upperTorso or not upperTorso:IsA("BasePart") then
        model:Destroy()
        return false
    end

    local nativeMotor = attachNativeRemote(model, root, upperTorso)

    local displayOverlay = model:FindFirstChild("Welds")
        and model.Welds:FindFirstChild("Cube.057")
    if displayOverlay and displayOverlay:IsA("BasePart") then
        displayOverlay.Transparency = 1
    end

    local screen = model:FindFirstChild("FPVScreen", true)
    local target = screen and screen:FindFirstChild("FPVScreenTarget")
    local center = model:FindFirstChild("ControllerCenter", true)
    print(("[RemotePose] center=%s screenTarget=%s leftGrip=%s rightGrip=%s")
        :format(
            center and tostring(getWorldCFrame(center).Position) or "missing",
            target and tostring(getWorldCFrame(target).Position) or "missing",
            leftGrip and tostring(getWorldCFrame(leftGrip).Position) or "missing",
            rightGrip and tostring(getWorldCFrame(rightGrip).Position) or "missing"
        ))



    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid and tool and tool.Parent ~= character then
        humanoid:EquipTool(tool)
    end

    remoteModel = model
    remoteWeld = nativeMotor

    bindRemoteVisibility()
    createCount += 1
    return true
end

function controller:StartLeftArmIKBlend()
    if leftArmIK then
        leftArmIK.Enabled = false
        leftArmIK:Destroy()
        leftArmIK = nil
    end

    if rightArmIK then
        rightArmIK.Enabled = false
        rightArmIK:Destroy()
        rightArmIK = nil
    end

    if leftArmIKTarget then
        leftArmIKTarget:Destroy()
        leftArmIKTarget = nil
    end

    if rightArmIKTarget then
        rightArmIKTarget:Destroy()
        rightArmIKTarget = nil
    end

    if leftElbowTarget then
        leftElbowTarget:Destroy()
        leftElbowTarget = nil
    end

    if handTrackingConnection then
        handTrackingConnection:Disconnect()
        handTrackingConnection = nil
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local leftUpperArm = character and character:FindFirstChild("LeftUpperArm")
    local rightUpperArm = character and character:FindFirstChild("RightUpperArm")
    local leftHand = character and character:FindFirstChild("LeftHand")
    local rightHand = character and character:FindFirstChild("RightHand")

    local leftGripTarget = remoteModel and remoteModel:FindFirstChild("LeftHandGripTarget", true)
    local rightGripTarget = remoteModel and remoteModel:FindFirstChild("RightHandGripTarget", true)

    if not humanoid
        or not leftUpperArm
        or not rightUpperArm
        or not leftHand
        or not rightHand
        or not leftGripTarget
        or not rightGripTarget
        or not leftGripTarget:IsA("Attachment")
        or not rightGripTarget:IsA("Attachment") then
        warn("[RemoteController] Hand IK targets or R15 arm parts are missing")
        return false
    end

    local leftTargetCFrame = leftGripTarget.WorldCFrame
    local rightTargetCFrame = rightGripTarget.WorldCFrame
    leftArmIKTarget = createTargetPart("DroneLeftHandTarget", leftTargetCFrame)
    rightArmIKTarget = createTargetPart("DroneRightHandTarget", rightTargetCFrame)

    leftArmIK = Instance.new("IKControl")
    leftArmIK.Name = "DroneLeftArmIK"
    leftArmIK.Type = Enum.IKControlType.Transform
    leftArmIK.ChainRoot = leftUpperArm
    leftArmIK.EndEffector = leftHand
    leftArmIK.Target = leftArmIKTarget
    leftArmIK.Weight = 0
    leftArmIK.Enabled = true
    leftArmIK.Parent = humanoid

    rightArmIK = Instance.new("IKControl")
    rightArmIK.Name = "DroneRightArmIK"
    rightArmIK.Type = Enum.IKControlType.Transform
    rightArmIK.ChainRoot = rightUpperArm
    rightArmIK.EndEffector = rightHand
    rightArmIK.Target = rightArmIKTarget
    rightArmIK.Weight = 0
    rightArmIK.Enabled = true
    rightArmIK.Parent = humanoid

    leftGrip = leftGripTarget
    rightGrip = rightGripTarget
    ikBlendRequested = true
    ikWeight = 0

    handTrackingConnection = RunService.RenderStepped:Connect(function(dt)
        if not remoteModel or not remoteModel.Parent then
            return
        end

        if leftArmIKTarget and leftGrip then
            leftArmIKTarget.CFrame = leftGrip.WorldCFrame * CFrame.new(0, 0.15, 0)
        end

        if rightArmIKTarget and rightGrip then
            rightArmIKTarget.CFrame = rightGrip.WorldCFrame * CFrame.new(0, 0.15, 0)
        end

        ikWeight = math.min(1, ikWeight + dt * 8)
        if leftArmIK then
            leftArmIK.Weight = ikWeight
        end
        if rightArmIK then
            rightArmIK.Weight = ikWeight
        end
    end)

    return true
end

function controller:HasRemote(): boolean
    local character = player.Character
    local tool = findTool()
    local model = character and character:FindFirstChild("HeldRemote")

    if model and model:IsA("Model") then
        remoteModel = model
    end

    if not remoteModel
        or not remoteModel.Parent
        or not character
        or not tool
        or tool.Parent ~= character then
        return false
    end

    for _, object in ipairs(remoteModel:GetDescendants()) do
        if object:IsA("BasePart")
            and object.Transparency < 1
            and object.LocalTransparencyModifier < 1 then
            return true
        end
    end

    return false
end

function controller:Destroy()
    clearRemote()
end

function controller:Cleanup()
    self:Destroy()
end

function controller:GetCreateCount(): number
    return createCount
end

function controller:Init()
end

function controller:Start()
end

return controller
