-- Copyright (C) by Jianhao Dai (Toruneko)

require "resty.upstream.math"
-- see https://github.com/hamishforbes/lua-resty-iputils.git
local iputils = require "resty.iputils"

local upstream = require "resty.upstream"

local tostring = tostring
local math_abs = math.abs

local _M = {
    _VERSION = '0.01'
}

local function get_round_robin_peer(u)
    local ups, err = upstream.get_upstream(u)
    if not ups then
        return nil, err
    end

    local current = ups.current

    local peer
    repeat
        ups.current = (ups.current % ups.size) + 1
        peer = ups.peers[ups.current]

        if not peer then
            return nil, "no peer found"
        end

        if current == ups.current and peer.down then
            return nil, "no avaliable peer"
        end

    until not peer.down

    return peer
end
_M.get_round_robin_peer = get_round_robin_peer

local function get_source_ip_hash_peer(u)
    local ups, err = upstream.get_upstream(u)
    if not ups then
        return nil, err
    end

    local src, err = math_abs(iputils.ip2bin(ngx.var.remote_addr))
    if not src then
        return nil, err
    end
    local current = (src % ups.size) + 1
    local peer = ups.peers[current]

    if not peer then
        return nil, "no peer found"
    end

    if peer.down then
        return get_round_robin_peer(u)
    end

    return peer
end
_M.get_source_ip_hash_peer = get_source_ip_hash_peer

local function get_weighted_round_robin_peer(u)
    local ups, err = upstream.get_upstream(u)
    if not ups then
        return nil, err
    end

    local current = ups.current
    local cw = ups.cw

    while true do
        ups.current = (ups.current % ups.size) + 1
        if ups.current == 1 then
            ups.cw = ups.cw - ups.gcd
            if ups.cw <= 0 then
                ups.cw = ups.max
            end
        end

        local peer = ups.peers[ups.current]

        if not peer then
            return nil, "no peer found: " .. tostring(u)
        end

        if peer.weight >= ups.cw then
            if not peer.down then
                return peer
            end
            -- 一个轮回，却没有找到一个有用的节点，赶紧退出。
            if ups.cw == cw and ups.current == current then
                return nil, "no avaliable peer: " .. tostring(u)
            end
        end
    end
end
_M.get_weighted_round_robin_peer = get_weighted_round_robin_peer

return _M