-- Copyright (C) by Jianhao Dai (Toruneko)

local bit = require "bit"

local lshift = bit.lshift
local rshift = bit.rshift
local band = bit.band

local math = math

local _M = {
    _VERSION = '0.0.1'
}

local function iseven(x)
    return band(x, 1) == 0
end

local function gcd(x, y)
    if x < y then
        return gcd(y, x)
    end

    if y == 0 then
        return x
    end

    if iseven(x) then
        if iseven(y) then
            -- gcd(x >> 1, y >> 1) << 1
            return lshift(gcd(rshift(x, 1), rshift(y, 1)), 1)
        else
            return gcd(rshift(x, 1), y)
        end
    else
        if iseven(y) then
            return gcd(x, rshift(y, 1))
        else
            return gcd(y, x - y)
        end
    end
end

function math.gcd(x, y)
    return gcd(x, y)
end

return {
    _VERSION = '0.01'
}