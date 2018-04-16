-- Copyright (C) by Jianhao Dai (Toruneko)

-- see https://github.com/hamishforbes/lua-resty-iputils.git
local iputils = require "resty.iputils"
iputils.enable_lrucache()

local balancer = require "ngx.balancer"
local upstream = require "ngx.upstream"

local tostring = tostring
local math_abs = math.abs
local getups = upstream.get_upstream

local function get_round_robin_peer(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    local cp = ups.cp

    local peer
    repeat
        ups.cp = (ups.cp % ups.size) + 1
        peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found"
        end

        -- visit all peers, but no one avaliable, exit.
        if cp == ups.cp and peer.down then
            return nil, "no available peer"
        end

    until not peer.down

    return peer
end

local function get_source_ip_hash_peer(u)
    local ups, err = getups(u)
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

local function get_weighted_round_robin_peer(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    local cp = ups.cp
    local cw = ups.cw

    while true do
        ups.cp = (ups.cp % ups.size) + 1
        if ups.cp == 1 then
            ups.cw = ups.cw - ups.gcd
            if ups.cw <= 0 then
                ups.cw = ups.max
            end
        end

        local peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found: " .. tostring(u)
        end

        if peer.weight >= ups.cw then
            if not peer.down then
                return peer
            end
        end
        -- visit all peers, but no one avaliable, exit.
        if ups.cw == cw and ups.cp == cp then
            return nil, "no available peer: " .. tostring(u)
        end
    end
end

balancer.get_round_robin_peer = get_round_robin_peer
balancer.get_source_ip_hash_peer = get_source_ip_hash_peer
balancer.get_weighted_round_robin_peer = get_weighted_round_robin_peer

return balancer