-- Copyright (C) by Jianhao Dai (Toruneko)
require "resty.upstream.math"
local lrucache = require "resty.upstream.lrucache"

local LOGGER = ngx.log
local NOTICE = ngx.NOTICE

local ngx_lua_version = ngx.config.ngx_lua_version
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
    _VERSION = '0.0.4'
}

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function(narr, nrec) return {} end
end

local upcache
local peercache

local function gen_peer_key(prefix, u, is_backup, id)
    if is_backup then
        return prefix .. u .. ":b:" .. id
    end
    return prefix .. u .. ":p:" .. id
end

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
    for _, peer in pairs(ups) do
        peers[#peers + 1] = peer
    end
    return peers
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
        -- name and host must not be nil
        if peer.name and peer.host then
            if peer.default_down then
                local key = gen_peer_key("d:", u, false, peer.name)
                local value, err = peercache:get(key)
                if value == nil then
                    peercache:set(key, peer.default_down)
                end
            end

            ups[peer.name] = {
                name = peer.name,
                host = peer.host,
                down = peer.default_down,
                port = tonumber(peer.port) or 8080,
                weight = tonumber(peer.weight) or 100,
                max_fails = tonumber(peer.max_fails) or 3,
                fail_timeout = tonumber(peer.fail_timeout) or 10
            }
        end
    end

    local old = upcache:get(u)
    if old then
        for _, peer in ipairs(old.peers) do
            local p = ups[peer.name]
            if p then
                if peer.down then
                    local key = gen_peer_key("d:", u, false, peer.name)
                    peercache:set(key, true)
                end
            end
        end
    end

    local peers = build_peers(ups, #hosts)
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
        backup_peers = {}, -- backup peers, not implement
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

    peercache = shdict
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
    local key = gen_peer_key("d:", u, is_backup, name)
    return peercache:set(key, value)
end

function _M.incr_peer_fails(u, is_backup, name, timeout)
    local key = gen_peer_key("f:", u, is_backup, name)
    if ngx_lua_version >= 10012 then
        return peercache:incr(key, 1, 0, timeout) or 0
    end
    local next, err = peercache:incr(key, 1)
    if not next then
        if err == "not found" or err == "not a number" then
            return peercache:set(key, 1, timeout) and 1 or 0
        end
        return 0
    end

    return next
end

function _M.set_peer_temporarily_down(u, is_backup, name, timeout)
    local key = gen_peer_key("t:", u, is_backup, name)
    return peercache:set(key, true, timeout)
end

function _M.check_peer_down(u, is_backup, name)
    local d_key = gen_peer_key("d:", u, is_backup, name)
    if peercache:get(d_key) then
        return true
    end

    local t_key = gen_peer_key("t:", u, is_backup, name)
    if peercache:get(t_key) then
        return true
    end

    return false
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