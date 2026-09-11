--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local config = require(ReplicatedStorage.Shared.Drone.DroneConfig)
local feedFovController = require(ReplicatedStorage.Shared.Drone.DroneFeedFovController)
local states = require(ReplicatedStorage.Shared.Drone.DroneStates)
local firearmCameraController = require(script.Parent.CameraController)
local stateEvent = ReplicatedStorage.Remotes:WaitForChild("DroneStateChanged")

local controller = {}
local currentPlayerFov = math.clamp(config.camera.normalFov, config.camera.minimumFov, config.camera.maximumFov)
local targetPlayerFov = currentPlayerFov
local fpv = false
local started = false
local transitionAlpha = 1
local transitionStart = CFrame.identity
local savedCameraType: EnumItem?
local savedCameraSubject: Instance?
local savedCameraCFrame: CFrame?
local savedCameraFov: number?
local savedCameraMode: Enum.CameraMode?
local savedMinZoomDistance: number?
local savedMaxZoomDistance: number?
local savedCameraOffset: Vector3?
local cameraRenderConnection: RBXScriptConnection?
local obstructionRenderBound = false
local unbindCameraRender: () -> ()
local screenFocusPosition: Vector3?

local viewportModel: Model?
local viewportEnvironment: Model?
local viewportCamera: Camera?
local viewportFrame: ViewportFrame?
local screenSurface: SurfaceGui?
local hiddenCameraParts: {[BasePart]: number} = {}

local function findDrone()
    local folder = Workspace:FindFirstChild("ActiveDrones")
    local drone = folder and folder:FindFirstChild(player.Name .. "_Drone")
    return drone and drone:IsA("Model") and drone or nil
end

local function hideCameraObstructions()
    local character = player.Character
    if not character then
        return
    end

    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("BasePart") then
            local accessory = object:FindFirstAncestorOfClass("Accessory")
            local tool = object:FindFirstAncestorOfClass("Tool")
            if object.Name == "Head"
                or object.Name == "UpperTorso"
                or object.Name == "LowerTorso"
                or object.Name == "HumanoidRootPart"
                or accessory
                or (tool and tool.Name ~= "Remote") then
                if hiddenCameraParts[object] == nil then
                    hiddenCameraParts[object] = object.LocalTransparencyModifier
                end
                object.LocalTransparencyModifier = 1
            end
        end
    end
end

local function restoreCameraObstructions()
    if obstructionRenderBound then
        RunService:UnbindFromRenderStep("DroneCameraObstructions")
        obstructionRenderBound = false
    end

    for part, transparency in pairs(hiddenCameraParts) do
        if part.Parent then
            part.LocalTransparencyModifier = transparency
        end
    end
    table.clear(hiddenCameraParts)
end

local function bindCameraObstructionRender()
    if obstructionRenderBound then
        return
    end

    RunService:BindToRenderStep(
        "DroneCameraObstructions",
        Enum.RenderPriority.Last.Value,
        function()
            if fpv then
                hideCameraObstructions()
            end
        end
    )
    obstructionRenderBound = true
end

local function getHeadPosition(): Vector3?
    local character = player.Character
    local head = character and character:FindFirstChild("Head")
    if head and head:IsA("BasePart") then
        return head.Position
    end

    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root.Position + Vector3.new(0, 1.5, 0)
    end

    return nil
end

local function getScreenSurfaceFace(screen: BasePart): Enum.NormalId
    local headPosition = getHeadPosition()
    if not headPosition then
        return Enum.NormalId.Front
    end

    local towardHead = headPosition - screen.Position
    if towardHead.Magnitude < 0.01 then
        return Enum.NormalId.Front
    end

    return Enum.NormalId.Front
end

local function ensureScreenFocus(screen: BasePart)
    local target = screen:FindFirstChild("FPVScreenTarget")
    if target and target:IsA("Attachment") then
        return
    end

    local focus = Instance.new("Attachment")
    focus.Name = "FPVScreenTarget"
    focus.CFrame = CFrame.identity
    focus.Parent = screen
end

local function findScreenPart(): BasePart?
    local character = player.Character
    local remote = character and character:FindFirstChild("HeldRemote")
    if not remote then
        return nil
    end

    local screen = remote:FindFirstChild("FPVScreen", true)
    if screen and screen:IsA("BasePart") then
        ensureScreenFocus(screen)
        return screen
    end

    local monitor = remote:FindFirstChild("Cube.056", true)
    if monitor and monitor:IsA("BasePart") then
        ensureScreenFocus(monitor)
        return monitor
    end

    local sourceTool = ReplicatedStorage:FindFirstChild("Remote")
    local sourceModel = sourceTool and sourceTool:FindFirstChild("RemoteModel")
    local sourceRoot = sourceModel and sourceModel:FindFirstChild("RemoteRoot", true)
    local sourceScreen = sourceModel and sourceModel:FindFirstChild("FPVScreen", true)
    local root = remote:FindFirstChild("RemoteRoot", true)

    if not sourceModel or not sourceRoot or not sourceRoot:IsA("BasePart")
        or not sourceScreen or not sourceScreen:IsA("BasePart")
        or not root or not root:IsA("BasePart") then
        return nil
    end

    local createdScreen = sourceScreen:Clone()
    createdScreen.CFrame = root.CFrame * sourceRoot.CFrame:ToObjectSpace(sourceScreen.CFrame)
    createdScreen.Parent = remote
    ensureScreenFocus(createdScreen)

    local weld = Instance.new("WeldConstraint")
    weld.Name = "RemoteScreenWeld"
    weld.Part0 = root
    weld.Part1 = createdScreen
    weld.Parent = root

    return createdScreen
end

local function findDisplayPart(remote: Model, marker: BasePart): BasePart
    local display = marker
    local displayArea = 0
    for _, object in ipairs(remote:GetDescendants()) do
        if object:IsA("BasePart") and object ~= marker then
            local size = object.Size
            local thin = math.min(size.X, size.Y, size.Z)
            local wide = math.max(size.X, size.Y, size.Z)
            local area = size.X * size.Y * size.Z
            if thin < 0.03 and wide > 0.5 and area > displayArea then
                display = object
                displayArea = area
            end
        end
    end
    return display
end

local function getDisplayFace(part: BasePart): Enum.NormalId
    local headPosition = getHeadPosition()
    if not headPosition then
        return Enum.NormalId.Left
    end

    local towardHead = (headPosition - part.Position).Unit
    local size = part.Size
    local axis
    local positiveFace
    local negativeFace

    if size.X <= size.Y and size.X <= size.Z then
        axis = part.CFrame.RightVector
        positiveFace = Enum.NormalId.Right
        negativeFace = Enum.NormalId.Left
    elseif size.Y <= size.X and size.Y <= size.Z then
        axis = part.CFrame.UpVector
        positiveFace = Enum.NormalId.Top
        negativeFace = Enum.NormalId.Bottom
    else
        axis = part.CFrame.LookVector
        positiveFace = Enum.NormalId.Front
        negativeFace = Enum.NormalId.Back
    end

    return axis:Dot(towardHead) >= 0 and positiveFace or negativeFace
end

local function ensureScreenFeed(): ViewportFrame?
    local screen = findScreenPart()
    if not screen then
        return nil
    end

    local remote = player.Character and player.Character:FindFirstChild("HeldRemote")
    local display
    local root = remote and remote:FindFirstChild("RemoteRoot", true)
    if remote and root and root:IsA("BasePart") then
        for _, object in ipairs(remote:GetDescendants()) do
            if object:IsA("BasePart") and object.Name == "Cube.057" then
                display = object
                break
            end
        end
    end

    if display and screen.Name == "FPVScreen" then
        for _, object in ipairs(root:GetChildren()) do
            if object.Name == "RemoteScreenWeld" then
                object:Destroy()
            end
        end
        screen.Size = display.Size + Vector3.new(0.01, 0.01, 0.01)
        screen.CFrame = display.CFrame

        local weld = Instance.new("WeldConstraint")
        weld.Name = "RemoteScreenWeld"
        weld.Part0 = root
        weld.Part1 = screen
        weld.Parent = root
    end

    local surface = screen:FindFirstChild("FPVSurface")
    local playerGui = player:FindFirstChild("PlayerGui")

    if (not surface or not surface:IsA("SurfaceGui")) and playerGui then
        for _, object in ipairs(playerGui:GetChildren()) do
            if object:IsA("SurfaceGui") and object.Name == "FPVSurface" then
                if not surface and object.Adornee == screen then
                    surface = object
                elseif object.Adornee == screen then
                    object:Destroy()
                end
            end
        end
    end

    if surface and not surface:IsA("SurfaceGui") then
        surface:Destroy()
        surface = nil
    end

    if not surface then
        local createdSurface = Instance.new("SurfaceGui")
        createdSurface.Name = "FPVSurface"
        createdSurface.Adornee = screen
        createdSurface.Face = getDisplayFace(screen)
        createdSurface.Parent = player:WaitForChild("PlayerGui")
        surface = createdSurface
    elseif surface.Parent ~= player:FindFirstChild("PlayerGui") then
        surface.Parent = player:WaitForChild("PlayerGui")
    end

    screenSurface = surface
    surface.Adornee = screen
    surface.Face = getDisplayFace(screen)
    surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
    surface.PixelsPerStud = 1000
    local screenAspect = math.max(screen.Size.Z, 0.01) / math.max(screen.Size.Y, 0.01)
    surface.CanvasSize = Vector2.new(1024, math.max(1, math.floor(1024 / screenAspect)))
    surface.AlwaysOnTop = true
    surface.LightInfluence = 0
    surface.Brightness = 2
    surface.ZOffset = 0.01
    surface.Enabled = true

    local view = surface:FindFirstChild("DroneView")
    if view and not view:IsA("ViewportFrame") then
        view:Destroy()
        view = nil
    end

    if not view then
        local createdView = Instance.new("ViewportFrame")
        createdView.Name = "DroneView"
        createdView.Size = UDim2.fromScale(1, 1)
        createdView.BackgroundTransparency = 0
        createdView.BackgroundColor3 = Color3.fromRGB(135, 200, 235)
        createdView.BorderSizePixel = 0
        createdView.ClipsDescendants = true
        createdView.Ambient = Color3.fromRGB(200, 200, 200)
        createdView.LightColor = Color3.fromRGB(255, 255, 255)
        createdView.Parent = surface
        view = createdView
    end

    view.Size = UDim2.fromScale(1, 1)
    view.BackgroundTransparency = 0
    view.BackgroundColor3 = Color3.fromRGB(135, 200, 235)
    view.BorderSizePixel = 0
    view.ClipsDescendants = true
    view.Visible = true
    view.Ambient = Color3.fromRGB(200, 200, 200)
    view.LightColor = Color3.fromRGB(255, 255, 255)

    return view
end

local function findScreen()
    return ensureScreenFeed()
end

local function isValidCameraTarget(target: Instance?): boolean
    if not target or not target:IsDescendantOf(Workspace) then
        return false
    end

    local position
    if target:IsA("Attachment") then
        position = target.WorldPosition
    elseif target:IsA("BasePart") then
        position = target.Position
    else
        return false
    end

    return position.Y > Workspace.FallenPartsDestroyHeight
end

local function getScreenCameraCFrame(): CFrame?
    local character = player.Character
    local remote = character and character:FindFirstChild("HeldRemote")
    local screen = findScreenPart()
    local target = screen and screen:FindFirstChild("FPVScreenTarget")
        or remote and remote:FindFirstChild("FPVScreenFocus", true)
    local head = character and character:FindFirstChild("Head")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not isValidCameraTarget(target) or not target:IsA("Attachment")
        or not screen or not head or not head:IsA("BasePart")
        or not root or not root:IsA("BasePart") then
        return nil
    end

    local screenPosition = target.WorldPosition
    screenFocusPosition = screenPosition

    local stableUp = root.CFrame.UpVector
    local outward = screenPosition - head.Position
    if outward.Magnitude < 0.1 then
        outward = -target.WorldCFrame.LookVector
    else
        outward = -outward.Unit
    end

    local viewingDistance = math.min(config.camera.screenMinimumDistance, 1.35)
    local shoulderOffset = root.CFrame.RightVector * 1.1
    local cameraPosition = screenPosition
        + outward * viewingDistance
        + shoulderOffset
        + stableUp * config.camera.screenVerticalOffset

    local fromHead = cameraPosition - head.Position
    if fromHead.Magnitude < config.camera.screenHeadClearance then
        cameraPosition = head.Position
            + root.CFrame.RightVector * config.camera.screenHeadClearance
            + stableUp * 0.2
    end

    return CFrame.lookAt(cameraPosition, screenPosition, stableUp)
end

local function getFirstPersonCameraCFrame(): CFrame?
    local character = player.Character
    local head = character and character:FindFirstChild("Head")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not head or not head:IsA("BasePart") or not root or not root:IsA("BasePart") then
        return nil
    end

    local forward = root.CFrame.LookVector
    local up = root.CFrame.UpVector
    local eyeClearance = math.max(head.Size.Z * 0.5 + 0.2, 0.65)
    local position = head.Position
        + up * 0.05
        + forward * eyeClearance

    return CFrame.lookAt(position, position + forward * 10, up)
end

local function updatePlayerCamera(dt: number)
    local camera = Workspace.CurrentCamera
    if not camera or not fpv then
        return
    end

    hideCameraObstructions()

    if transitionAlpha < 1 then
        camera.CameraType = Enum.CameraType.Scriptable
        transitionAlpha = math.min(1, transitionAlpha + dt / config.camera.transitionTime)
        local easedAlpha = transitionAlpha * transitionAlpha * (3 - 2 * transitionAlpha)
        local screenTarget = getScreenCameraCFrame()
        local transitionTarget = transitionStart

        if screenTarget then
            transitionTarget = transitionStart:Lerp(screenTarget, easedAlpha)
        end

        camera.CFrame = transitionTarget
        if transitionAlpha >= 1 then
            local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
            camera.CameraType = Enum.CameraType.Custom
            player.CameraMode = savedCameraMode or Enum.CameraMode.Classic
            if humanoid then
                camera.CameraSubject = humanoid
                humanoid.CameraOffset = savedCameraOffset or Vector3.zero
            end
            unbindCameraRender()
        end
    end
end

local function bindCameraRender()
    if cameraRenderConnection then
        return
    end

    cameraRenderConnection = RunService.Heartbeat:Connect(updatePlayerCamera)
end

unbindCameraRender = function()
    if not cameraRenderConnection then
        return
    end

    cameraRenderConnection:Disconnect()
    cameraRenderConnection = nil
end

local function clearViewport()
    if viewportFrame then
        viewportFrame.Visible = false
    end

    if viewportModel then
        viewportModel:Destroy()
        viewportModel = nil
    end

    if viewportEnvironment then
        viewportEnvironment:Destroy()
        viewportEnvironment = nil
    end

    if viewportCamera then
        viewportCamera:Destroy()
        viewportCamera = nil
    end

    if screenSurface then
        screenSurface:Destroy()
        screenSurface = nil
    end

    viewportFrame = nil
end

local function copyEnvironmentPart(part: BasePart, environment: Model)
    local copy = part:Clone()
    for _, object in ipairs(copy:GetDescendants()) do
        if object:IsA("BaseScript")
            or object:IsA("JointInstance")
            or object:IsA("Constraint")
            or object:IsA("Attachment") then
            object:Destroy()
        end
    end

    copy.Anchored = true
    copy.CanCollide = false
    copy.CanTouch = false
    copy.CanQuery = false
    copy.CFrame = part.CFrame
    copy.Parent = environment
end

local function createViewportEnvironment(): Model
    local environment = Instance.new("Model")
    environment.Name = "DroneEnvironment"

    local activeDrones = Workspace:FindFirstChild("ActiveDrones")
    local character = player.Character
    local origin = character and character:GetPivot().Position or Vector3.zero
    local candidates: {BasePart} = {}

    local function addCandidate(part: BasePart)
        if part.Size.Magnitude > 0.05 then
            table.insert(candidates, part)
        end
    end

    for _, object in ipairs(Workspace:GetChildren()) do
        local skip = object == activeDrones
            or object == character
            or object:IsA("Camera")
            or object:IsA("Terrain")
            or object:IsA("Tool")
            or object.Name == "Drone"
            or object.Name == "Remote"

        if not skip and not (object:IsA("Model") and object:FindFirstChildOfClass("Humanoid")) then
            if object:IsA("BasePart") then
                addCandidate(object)
            else
                for _, descendant in ipairs(object:GetDescendants()) do
                    if descendant:IsA("BasePart") then
                        addCandidate(descendant)
                    end
                end
            end
        end
    end

    table.sort(candidates, function(left, right)
        return (left.Position - origin).Magnitude < (right.Position - origin).Magnitude
    end)

    for index = 1, math.min(#candidates, 1200) do
        copyEnvironmentPart(candidates[index], environment)
    end

    environment.Parent = viewportFrame
    return environment
end

local function setupViewport(drone: Model)
    if viewportFrame
        and viewportFrame.Parent
        and viewportModel
        and viewportModel.Parent
        and viewportEnvironment
        and viewportEnvironment.Parent
        and viewportCamera
        and viewportCamera.Parent then
        return
    end

    clearViewport()

    local view = findScreen()
    if not view then
        return
    end

    viewportFrame = view
    viewportFrame.Visible = true
    viewportFrame:ClearAllChildren()

    viewportEnvironment = createViewportEnvironment()

    viewportModel = drone:Clone()
    for _, object in ipairs(viewportModel:GetDescendants()) do
        if object:IsA("BaseScript") or object:IsA("Camera") or object:IsA("WeldConstraint") then
            object:Destroy()
        elseif object:IsA("BasePart") then
            object.Anchored = true
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
        end
    end
    viewportModel.Parent = viewportFrame

    viewportCamera = Instance.new("Camera")
    viewportCamera.Name = "DroneViewCamera"
    viewportCamera.Parent = viewportFrame
    viewportFrame.CurrentCamera = viewportCamera
end

local function updateViewport(drone: Model)
    if not viewportModel or not viewportCamera or not viewportFrame then
        setupViewport(drone)
    end

    if not viewportModel or not viewportCamera then
        return
    end

    local dronePivot = drone:GetPivot()
    viewportModel:PivotTo(dronePivot)

    local sourceCamera = drone:FindFirstChild("FPVCamera", true)
    local sourceCFrame = drone:GetAttribute("FPVCameraCFrame")
    local droneRoot = drone.PrimaryPart or drone:FindFirstChild("DroneRoot", true)

    if sourceCamera and sourceCamera:IsA("Camera") then
        viewportCamera.CFrame = sourceCamera.CFrame
        viewportCamera.FieldOfView = math.clamp(
            sourceCamera.FieldOfView,
            config.feedFov.minimumFov,
            config.feedFov.maximumFov
        )
    elseif typeof(sourceCFrame) == "CFrame" then
        viewportCamera.CFrame = sourceCFrame
    else
        viewportCamera.CFrame = droneRoot.CFrame * CFrame.new(0, 2.2, -5.5)
    end

    local currentScreen = findScreenPart()
    if screenSurface and currentScreen then
        screenSurface.Adornee = currentScreen
        screenSurface.Face = getDisplayFace(currentScreen)
    end

    viewportCamera.FieldOfView = feedFovController:GetCurrentFov()
end

local function showPreview()
    local drone = findDrone()
    if not drone then
        return
    end

    setupViewport(drone)
    updateViewport(drone)
end

local function enterFpv(): boolean
    if fpv then
        return true
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return false
    end

    savedCameraType = camera.CameraType
    savedCameraSubject = camera.CameraSubject
    savedCameraCFrame = camera.CFrame
    savedCameraFov = camera.FieldOfView
    savedCameraMode = player.CameraMode
    savedMinZoomDistance = player.CameraMinZoomDistance
    savedMaxZoomDistance = player.CameraMaxZoomDistance
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        savedCameraOffset = humanoid.CameraOffset
    end
    player.CameraMode = Enum.CameraMode.Classic
    player.CameraMinZoomDistance = 0.5
    player.CameraMaxZoomDistance = 20
    firearmCameraController.Deactivate()
    hideCameraObstructions()
    transitionStart = camera.CFrame
    fpv = true
    transitionAlpha = 0
    bindCameraObstructionRender()
    bindCameraRender()
    currentPlayerFov = savedCameraFov or currentPlayerFov
    targetPlayerFov = currentPlayerFov
    feedFovController:Reset()
    return true
end

local function restoreCamera()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    camera.CameraType = savedCameraType or Enum.CameraType.Custom
    if savedCameraSubject and savedCameraSubject.Parent then
        camera.CameraSubject = savedCameraSubject
    else
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            camera.CameraSubject = humanoid
        end
    end

    if savedCameraCFrame then
        camera.CFrame = savedCameraCFrame
    end
    camera.FieldOfView = math.clamp(
        savedCameraFov or config.camera.normalFov,
        config.camera.minimumFov,
        config.camera.maximumFov
    )
end

local function exitFpv()
    restoreCameraObstructions()
    unbindCameraRender()
    transitionAlpha = 1
    fpv = false
    screenFocusPosition = nil
    targetPlayerFov = math.clamp(config.camera.normalFov, config.camera.minimumFov, config.camera.maximumFov)
    currentPlayerFov = savedCameraFov or targetPlayerFov
    feedFovController:Reset()
    clearViewport()
    restoreCamera()
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid and savedCameraOffset then
        humanoid.CameraOffset = savedCameraOffset
    end
    player.CameraMode = savedCameraMode or Enum.CameraMode.Classic
    savedCameraType = nil
    savedCameraSubject = nil
    savedCameraCFrame = nil
    savedCameraFov = nil
    savedCameraMode = nil
    if savedMinZoomDistance then
        player.CameraMinZoomDistance = savedMinZoomDistance
    end
    if savedMaxZoomDistance then
        player.CameraMaxZoomDistance = savedMaxZoomDistance
    end
    savedMinZoomDistance = nil
    savedMaxZoomDistance = nil
    savedCameraOffset = nil
end

function controller:Enter(): boolean
    showPreview()
    local entered = enterFpv()
    if entered then
        task.spawn(function()
            for _ = 1, 20 do
                if not fpv or viewportFrame then
                    break
                end
                showPreview()
                task.wait(0.1)
            end
        end)
    end
    return entered
end

function controller:IsTransitionComplete(): boolean
    return fpv
end

function controller:Exit()
    exitFpv()
end

function controller:Init()
    local camera = Workspace.CurrentCamera
    if camera then
        camera.CameraType = Enum.CameraType.Custom
        camera.CameraSubject = player.Character and player.Character:FindFirstChildOfClass("Humanoid") or camera.CameraSubject
        camera.FieldOfView = math.clamp(config.camera.normalFov, config.camera.minimumFov, config.camera.maximumFov)
    end
end

function controller:Start()
    if started then
        return
    end

    started = true

    RunService.Heartbeat:Connect(function(dt)
        local camera = Workspace.CurrentCamera
        local difference = targetPlayerFov - currentPlayerFov
        local step = config.camera.fovChangeSpeed * dt

        currentPlayerFov = math.abs(difference) <= step
            and targetPlayerFov
            or currentPlayerFov + (difference > 0 and step or -step)

        feedFovController:Update(dt)

        if camera and fpv then
            camera.FieldOfView = math.clamp(
                currentPlayerFov,
                config.camera.minimumFov,
                config.camera.maximumFov
            )
        end

        local drone = findDrone()
        if drone then
            if fpv then
                player.CameraMode = savedCameraMode or Enum.CameraMode.Classic
                hideCameraObstructions()
                setupViewport(drone)
                updateViewport(drone)

            elseif viewportFrame then
                updateViewport(drone)
            end
        elseif fpv and transitionAlpha >= 1 then
            exitFpv()
        end
    end)

    stateEvent.OnClientEvent:Connect(function(nextState)
        nextState = type(nextState) == "table" and nextState.state or nextState
        if nextState == states.RemoteIdle then
            showPreview()
        elseif nextState == states.EnteringFPV then
            showPreview()
            enterFpv()
        elseif nextState == states.ControllingDrone then
            showPreview()
            if not fpv then
                enterFpv()
            end
        elseif nextState == states.ExitingDrone or nextState == states.Unequipped then
            exitFpv()
        end
    end)

    player.CharacterRemoving:Connect(function()
        exitFpv()
    end)
end

return controller

