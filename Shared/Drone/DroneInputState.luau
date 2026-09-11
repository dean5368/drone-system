--!strict

local fields = {
    "forward",
    "sideways",
    "vertical",
    "speed",
    "roll",
    "yaw",
}

local values = {
    forward = 0,
    sideways = 0,
    vertical = 0,
    speed = 0,
    roll = 0,
    yaw = 0,
}

local inputState = {}

function inputState:Set(name: string, value: number)
    if values[name] == nil then
        return
    end

    values[name] = math.clamp(value, -1, 1)
end

function inputState:Get()
    local result = {}
    for _, name in ipairs(fields) do
        result[name] = values[name]
    end
    return result
end

function inputState:Clear()
    for _, name in ipairs(fields) do
        values[name] = 0
    end
end

return inputState

