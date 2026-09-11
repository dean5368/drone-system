--!strict

local DroneConfig = {
    movement = {
        startingSpeed = 24,
        minimumSpeed = 18,
        normalSpeed = 32,
        maximumSpeed = 64,
        acceleration = 14,
        deceleration = 18,
        speedChangeRate = 24,
        accelerationResponsiveness = 8,
        hoverHeight = 8,
        hoverResponsiveness = 6,
        hoverBobHeight = 0.12,
        hoverBobSpeed = 2.2,
        maximumClimbSpeed = 18,
        maximumDescentSpeed = 12,
        maximumFlightDistance = 500,
        inputTimeout = 0.75,
        maximumPitchAngle = 15,
        maximumRollAngle = 30,
        bankTurnRate = 45,
        turnAssistSpeed = 12,
        reverseSpeedMultiplier = 0.45,
    },

    modelForwardCorrection = CFrame.identity,
    DroneHoldOffset = CFrame.new(0, 2.316, -1.03),
    DroneModelOrientationOffset = CFrame.Angles(0, math.rad(180), 0),
    deployment = {
        releaseHandOffset = CFrame.new(0, 0, -0.35),
        holdingHandOffset = CFrame.new(0.4, 1, -0.55),
        heldDroneScale = 1,
        remoteHandOffset = CFrame.new(0, -0.05, -0.15),
        launchForwardOffset = 1.5,
        hoverForwardOffset = 8,
        hoverVerticalOffset = 2,
        launchDuration = 0.4,
        hoverDuration = 0.5,
    },

    propeller = {
        rotationSpeed = 540,
    },

    roll = {
        maximumAngle = 30,
        responseSpeed = 4,
        recoverySpeed = 8,
    },

    joystick = {
        maximumAngle = math.rad(22),
        sidewaysAngle = math.rad(30),
        responseSpeed = 14,
        returnSpeed = 10,
    },

    camera = {
        normalFov = 70,
        fpvFov = 65,
        minimumFov = 35,
        maximumFov = 90,
        transitionTime = 0.6,
        screenDistance = 3.5,
        screenMinimumDistance = 3.25,
        screenHeadClearance = 0.55,
        screenVerticalOffset = 0.35,
        fovChangeSpeed = 8,
    },

    feedFov = {
        currentFov = 65,
        targetFov = 65,
        minimumFov = 35,
        maximumFov = 90,
        defaultFov = 65,
        transitionSpeed = 8,
    },

    input = {
        deploy = Enum.KeyCode.F,
        forward = Enum.KeyCode.W,
        backward = Enum.KeyCode.S,
        left = Enum.KeyCode.A,
        right = Enum.KeyCode.D,
        speedUp = Enum.KeyCode.Unknown,
        slowDown = Enum.KeyCode.Unknown,
        rollLeft = Enum.KeyCode.Left,
        rollRight = Enum.KeyCode.Right,
        verticalUp = Enum.KeyCode.Up,
        verticalDown = Enum.KeyCode.Down,
        yawLeft = Enum.KeyCode.Unknown,
        yawRight = Enum.KeyCode.Unknown,
    },

    animationMarkers = {
        releaseDrone = "ReleaseDrone",
        remoteReady = "RemoteReady",
    },

    animationTiming = {
        droneReleaseTime = 0.61,
        remoteEquipReadyTime = 0.6,
    },

    inputSendRate = 1 / 20,
}

return DroneConfig

