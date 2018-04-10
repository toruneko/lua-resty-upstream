-- Copyright (C) by Jianhao Dai (Toruneko)

local lrucache = require "ngx.upstream.lrucache"

local LOGGER = ngx.log
local ERROR = ngx.ERR
local NOTICE = ngx.NOTICE
local WARN = ngx.WARN
local INFO = ngx.INFO
local DEBUG = ngx.DEBUG

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

local upcache

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function(narr, nrec) return {} end
end

local function table_size(tab)
    local size = 0
    for _, item in pairs(tab) do
        size = size + 1
    end
    return size
end

local function table_values(tab, size)
    if not size then
        size = table_size(tab)
    end

    local arr = new_tab(size, 0)
    for _, val in pairs(tab) do
        arr[#arr + 1] = val
    end

    return arr
end

local function getgcd(hosts)
    local gcd = 0
    for _, peer in ipairs(hosts) do
        gcd = math_gcd(peer.weight, gcd)
    end
    return gcd
end

local function getmax(hosts)
    local max = 0
    for _, peer in ipairs(hosts) do
        max = math_max(max, peer.weight)
    end
    return max
end

local function create_index(hosts)
    local index = new_tab(0, table_size(hosts))
    for idx, peer in pairs(hosts) do
        index[peer.host] = idx
    end
    return index
end

local function update_upstream(u, data)
    local version = tonumber(data.version)
    local hosts = data.hosts
    if not hosts then
        LOGGER(NOTICE, "no hosts data: ", u)
        return
    end

    local ups = new_tab(0, #hosts)
    for _, peer in ipairs(hosts) do
        peer.port = tonumber(peer.port) or 8080
        peer.weight = tonumber(peer.weight) or 100
        peer.max_fails = tonumber(peer.max_fails) or 3
        peer.fail_timeout = tonumber(peer.fail_timeout) or 10
        peer.down = peer.default_down and true or false
        -- 必须要有host
        if peer.host then
            ups[peer.host .. peer.port] = peer
        end
    end

    local old = upcache:get(u)
    if old then
        -- 存在节点，合并健康检查状态和权值
        for _, peer in ipairs(old.peers) do
            local p = ups[peer.host .. peer.port]
            if p then
                p.down = peer.down
            end
        end
    end

    ups = table_values(ups, #hosts)
    local max = getmax(ups)
    local gcd = getgcd(ups)
    upcache:set(u, {
        version = version,
        current = 1, -- 当前节点
        size = #ups, -- 节点数量
        gcd = gcd, -- 最大公约数
        max = max, -- 最大权值
        cw = max, -- 当前权值
        peers = ups, -- 节点
        index = create_index(ups), -- 节点索引
        backup_peers = {}, -- 备用节点
        backup_index = create_index({}) -- 备用节点索引
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

function _M.init(config)
    local shdict = shared[config.cache]
    if not shared then
        error("no shared cache")
    end
    upcache = lrucache(shdict, config.cache_size or 10000)
end

function _M.update_upstream(u, data)
    update_upstream(u, data)
end

function _M.delete_upstream(u)
    upcache:delete(u)
end

function _M.set_peer_down(u, is_backup, host, value)
    local ups, err = getups(u)
    if not ups then
        return nil, err
    end

    if is_backup then
        local idx = ups.backup_index[host]
        ups.backup_peers[idx].down = value
    else
        local idx = ups.index[host]
        ups.peers[idx].down = value
    end
    -- set回去，以便更新ups让其他worker发现
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