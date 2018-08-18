-- Copyright (C) by Jianhao Dai (Toruneko)
require "ngx.upstream.math"
local lrucache = require "ngx.upstream.lrucache"

local LOGGER = ngx.log
local NOTICE = ngx.NOTICE

local tostring = tostring
local tonumber = tonumber
local shared = ngx.shared
local ipairs = ipairs
local pairs = pairs
local error = error
local pcall = pcall
local math_max = math.max
local math_gcd = math.gcd

local _M = {
    _VERSION = '0.01'
}

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function(narr, nrec) return {} end
end

local upcache

local function getgcd(peers)
    local gcd = 0
    for _, peer in ipairs(peers) do
        gcd = math_gcd(peer.weight, gcd)
    end
    return gcd
end

local function getmax(peers)
    local max = 0
    for _, peer in ipairs(peers) do
        max = math_max(max, peer.weight)
    end
    return max
end

local function build_peers(ups, size)
    local peers = new_tab(size, 0)
    local index = new_tab(0, size)
    for name, peer in pairs(ups) do
        peers[#peers + 1] = peer
        index[name] = #peers
    end
    return peers, index
end

local function update_upstream(u, data)
    local version = tonumber(data.version)
    local hosts = data.hosts
    if not hosts then
        LOGGER(NOTICE, "no hosts data: ", u)
        return false
    end

    local ups = new_tab(0, #hosts)
    for _, peer in ipairs(hosts) do
        peer.port = tonumber(peer.port) or 8080
        peer.weight = tonumber(peer.weight) or 100
        peer.max_fails = tonumber(peer.max_fails) or 3
        peer.fail_timeout = tonumber(peer.fail_timeout) or 10
        peer.down = peer.default_down and true or false
        peer.default_down = nil -- remove default_down field
        peer.fails = 0      -- current fails times during fail_timeout
        peer.checked = 0    -- check failed time
        peer.timeout = 0    -- failed timeout (ngx.time() + fail_timeout)
        -- name and host must not be nil
        if peer.name and peer.host then
            ups[peer.name] = peer
        end
    end

    local old = upcache:get(u)
    if old then
        -- exists already, merge healthcehck status
        for _, peer in ipairs(old.peers) do
            local p = ups[peer.name]
            if p then
                p.down = peer.down
            end
        end
    end

    local peers, index = build_peers(ups, #hosts)
    local max = getmax(peers)
    local gcd = getgcd(peers)
    return upcache:set(u, {
        version = version,
        cp = 1, -- current peer index
        size = #peers, -- peers count size
        gcd = gcd, -- GCD
        max = max, -- max weight
        cw = max, -- current weight
        peers = peers, -- peers
        index = index, -- peers index
        backup_peers = {}, -- backup peers, not implement
        backup_index = {} -- backup peers index, not implement
    })
end

local function getups(u)
    if not u then
        return nil, "invalid resolver"
    end

    local ups = upcache:get(u)
    if not ups then
        return nil, "no resolver defined: " .. tostring(u)
    end

    return ups
end

local function saveups(u, delete)
    local data = upcache:get("lua.resty.upstream")
    if not data then
        data = {}
    end
    if delete then
        data[u] = nil
    else
        data[u] = true
    end
    upcache:set("lua.resty.upstream", data)
end

function _M.init(config)
    local shdict = shared[config.cache]
    if not shared then
        error("no shared cache")
    end
    upcache = lrucache.new(shdict, config.cache_size or 1000)

    upcache:delete("lua.resty.upstream")
end

function _M.update_upstream(u, data)
    local ok = update_upstream(u, data)
    if ok then
        saveups(u)
    end
    return ok
end

function _M.delete_upstream(u)
    upcache:delete(u)
    saveups(u, true)
end

function _M.get_upstream(u)
    return getups(u)
end

function _M.get_upstreams()
    local data = upcache:get("lua.resty.upstream")
    if not data then
        return {}
    end

    local ups = {}
    for key, _ in pairs(data) do
        ups[#ups + 1] = key
    end
    return ups
end

function _M.set_peer_down(u, is_backup, name, value)
    local ups, err = getups(u)
    if not ups then
        return false, err
    end

    if is_backup then
        local idx = ups.backup_index[name]
        if not idx then
            return false, "no peer found"
        end
        ups.backup_peers[idx].down = value
    else
        local idx = ups.index[name]
        if not idx then
            return false, "no peer found"
        end
        ups.peers[idx].down = value
    end
    -- update cache, make other worker process to read
    return upcache:set(u, ups)
end

function _M.get_primary_peers(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    return ups.peers
end

function _M.get_backup_peers(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    return ups.backup_peers
end

function _M.get_version(u)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    return ups.version
end

return _M