-- Copyright (C) by Jianhao Dai (Toruneko)

-- see https://github.com/hamishforbes/lua-resty-iputils.git
local iputils = require "resty.iputils"
iputils.enable_lrucache()

local balancer = require "ngx.balancer"
local upstream = require "ngx.upstream"

local LOGGER = ngx.log
local WARN = ngx.WARN

local setmetatable = setmetatable
local tostring = tostring
local tonumber = tonumber
local math_abs = math.abs
local error = error
local type = type

local getups = upstream.get_upstream
local check_peer_down = upstream.check_peer_down
local incr_peer_fails = upstream.incr_peer_fails
local set_peer_temporarily_down = upstream.set_peer_temporarily_down

local function get_single_peer(ups, u)
    local peer = ups.peers[1]
    if not check_peer_down(u, false, peer.name) then
        return peer
    end
    return nil, "no available peer: " .. tostring(u)
end

local function get_round_robin_peer(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    if ups.size == 1 then
        return get_single_peer(ups, u)
    end

    local cp = ups.cp

    local peer
    repeat
        ups.cp = (ups.cp % ups.size) + 1
        peer = ups.peers[ups.cp]

        if not peer then
            return nil, "no peer found: " .. tostring(u)
        end

        -- visit all peers, but no one avaliable, exit.
        if cp == ups.cp and check_peer_down(u, false, peer.name) then
            return nil, "no available peer: " .. tostring(u)
        end

    until not check_peer_down(u, false, peer.name)

    return peer
end

local function get_source_ip_hash_peer(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    if ups.size == 1 then
        return get_single_peer(ups, u)
    end

    local src, err = math_abs(iputils.ip2bin(ngx.var.remote_addr))
    if not src then
        return nil, err
    end
    local current = (src % ups.size) + 1
    local peer = ups.peers[current]

    if not peer then
        return nil, "no peer found: " .. tostring(u)
    end

    if check_peer_down(u, false, peer.name) then
        return get_round_robin_peer(u)
    end

    return peer
end

local function get_weighted_round_robin_peer(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    if ups.size == 1 then
        return get_single_peer(ups, u)
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

        if peer.weight >= ups.cw and not check_peer_down(u, false, peer.name) then
            return peer
        end
        -- visit all peers, but no one avaliable, exit.
        if ups.cw == cw and ups.cp == cp then
            return nil, "no available peer: " .. tostring(u)
        end
    end
end

local function proxy_pass(peer_factory, u, tries, include)
    if not type(peer_factory) == "function" then
        error("peer_factory must be a function")
    end
    tries = tonumber(tries) or 0
    if not include then
        tries = tries - 1
    end

    if tries <= 0 then
        local peer, err = peer_factory(u)
        if not peer then
            return nil, err
        end
        return balancer.set_current_peer(peer.host, peer.port)
    end

    local ctx = ngx.ctx

    -- check fails
    local state, status = balancer.get_last_failure()
    if state then
        local last_peer = ctx.balancer_last_peer
        if last_peer and last_peer.max_fails > 0 then
            local fails = incr_peer_fails(u, false, last_peer.name, last_peer.fail_timeout)
            if fails >= last_peer.max_fails then
                set_peer_temporarily_down(u, false, last_peer.name, last_peer.fail_timeout)
                LOGGER(WARN, last_peer.name, " temporarily unavailable.")
            end
        end
    end

    -- check tries
    if not ctx.balancer_proxy_times then
        ctx.balancer_proxy_times = 0
    end
    if include and ctx.balancer_proxy_times >= tries then
        return nil, "max tries"
    end

    local peer, err = peer_factory(u)
    if not peer then
        return nil, err
    end

    -- check and set more tries
    if ctx.balancer_proxy_times < tries then
        local ok, err = balancer.set_more_tries(1)
        if not ok then
            return nil, err
        end
    end

    ctx.balancer_last_peer = peer
    ctx.balancer_proxy_times = ctx.balancer_proxy_times + 1
    return balancer.set_current_peer(peer.host, peer.port)
end

local mt = { __index = balancer }
local _M = setmetatable({
    _VERSION = upstream._VERSION,
    get_round_robin_peer = get_round_robin_peer,
    get_source_ip_hash_peer = get_source_ip_hash_peer,
    get_weighted_round_robin_peer = get_weighted_round_robin_peer,
    proxy_pass = proxy_pass
}, mt)

return _M