-- Copyright (C) by Jianhao Dai (Toruneko)
require "resty.upstream.math"

local lrucache = require "resty.upstream.lrucache"
-- see https://github.com/hamishforbes/lua-resty-iputils.git
local iputils = require "resty.iputils"

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
local math_abs = math.abs

local _M = {
    _VERSION = '0.01'
}

local etcd
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
        gcd = math_gcd(peer.weight or 100, gcd)
    end
    return gcd
end

local function getmax(hosts)
    local max = 0
    for _, peer in ipairs(hosts) do
        max = math_max(max, peer.weight or 100)
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

local function change_event(ctx, data, err)
    if not data then
        LOGGER(NOTICE, "app:", ctx.app, ", ups:", ctx.ups, ", err:", err)
        return
    end
    local version = tonumber(data.version)
    local hosts = data.hosts
    if not hosts then
        LOGGER(NOTICE, "no hosts data: ", ctx.app, ",", ctx.ups)
        return
    end

    local ups = {}
    for _, peer in ipairs(hosts) do
        if peer.port then
            peer.port = tonumber(peer.port)
        else
            peer.port = 8088 -- 没有port，默认为8088
        end
        if peer.weight then
            peer.weight = tonumber(peer.weight)
        else
            peer.weight = 100 -- 没有权值，默认为100
        end
        peer.down = false -- default down false
        -- 必须要有host
        if peer.host then
            ups[peer.host] = peer
        end
    end

    local old = upcache:get(ctx.ups)
    if old then
        -- 存在节点，合并健康检查状态和权值
        for _, peer in ipairs(old.peers) do
            local p = ups[peer.host]
            if p then
                p.down = peer.down
                if peer.weight then
                    p.weight = peer.weight
                end
            end
        end
    end

    ups = table_values(ups)
    local max = getmax(ups)
    local gcd = getgcd(ups)
    upcache:set(ctx.ups, {
        version = version,
        current = 1, -- 当前节点
        size = #ups, -- 节点数量
        gcd = gcd, -- 最大公约数
        max = max, -- 最大权值
        cw = max, -- 当前权值
        peers = ups, -- 节点
        index = create_index(ups) -- 节点索引
    })
end

local function getups(u)
    if not u then
        return nil, "invalid upstream"
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

function _M.watcher(ups)
end

function _M:unwatcher(ups)
end

function _M.get_upstreams()
    return {}
end

function _M.set_peer_down(u, is_backup, host, value)
    if not u then
        return nil, "invalid upstream"
    end
    local upstream = upcache:get(u)
    if not upstream then
        return nil, "no resolver defined: " .. tostring(u)
    end

    local idx = upstream.index[host]
    upstream.peers[idx].down = value
    -- set回去，以便更新ups让其他worker发现
    return upcache:set(u, upstream)
end

function _M.get_primary_peers(u)
    if not u then
        return nil, "invalid resolver"
    end
    local upstream = upcache:get(u)
    if not upstream then
        return nil, "no resolver defined: " .. tostring(u)
    end
    return upstream.peers
end

function _M.get_backup_peers(u)
    return {}
end

function _M.get_version(u)
    if not u then
        return nil, "invalid upstream"
    end
    local upstream = upcache:get(u)
    if not upstream then
        return nil, "no resolver defined: " .. tostring(u)
    end
    return upstream.version
end

function _M.get_source_ip_hash_peer(u)
    local ups, err = upcache(u)
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
        return _M.get_round_robin_peer(u)
    end

    return peer
end

function _M.get_round_robin_peer(u)
    local ups, err = upcache(u)
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

function _M.get_weighted_round_robin_peer(u)
    local ups, err = getups(u)
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

return _M