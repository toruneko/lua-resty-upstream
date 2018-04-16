-- Copyright (C) by Jianhao Dai (Toruneko)

local cjson = require "cjson.safe"

local setmetatable = setmetatable

-- @see https://github.com/openresty/lua-resty-lrucache
local ok, lrucache = pcall(require, "resty.lrucache")
if not ok then
    error("lua-resty-lrucache module required")
end

local _M = {
    _VERSION = '0.01'
}
local mt = { __index = _M }

-- init_by_lua
function _M.new(shdict, size)
    if not size then
        size = 1000
    end

    local self = {
        cache = lrucache.new(size),
        shdict = shdict
    }
    return setmetatable(self, mt)
end

function _M.get(self, key)
    local cache = self.cache
    local shdict = self.shdict
    local vkey = "v:" .. key

    local c = cache:get(key)
    -- missing in local cache.
    if not c then
        -- get from shared cache, write to local cache.
        local data = shdict:get(key)
        if not data then
            return nil, "no data"
        end

        data = cjson.decode(data)
        if not data then
            return nil, "invalid data"
        end

        local ver = shdict:get(vkey)
        if not ver then
            local succ, err = shdict:set(vkey, 1, data.ttl or 0)
            if not succ then
                return nil, err
            end
        end
        cache:set(key, { ver = ver or 1, data = data.val }, data.ttl)

        return data.val, ver
    end

    local ver = shdict:get(vkey)
    -- version data missing in shared cache, maybe deleted
    if not ver then
        return nil, "no version"
    end

    -- judge the local cache version and shared cache version.
    if ver == c.ver then
        return c.data, c.ver
    end

    -- data has been updated, should be write to local cache.
    local data = shdict:get(key)
    if not data then
        return nil, "no data"
    end

    data = cjson.decode(data)
    if not data then
        return nil, "invalid data"
    end

    cache:set(key, { ver = ver, data = data.val }, data.ttl)

    return data.val, ver
end

function _M.set(self, key, value, ttl)
    local shdict = self.shdict
    local vkey = "v:" .. key

    -- update shared cache only, local cache will be update when invoke get method.
    local succ, err = shdict:set(key, cjson.encode({ val = value, ttl = ttl }), ttl or 0)
    if not succ then
        return false, err
    end

    shdict:add(vkey, 0, ttl or 0)
    local new_v, err = shdict:incr(vkey, 1)
    if not new_v then
        return false, err
    end

    return true
end

function _M.delete(self, key)
    local shdict = self.shdict
    local vkey = "v:" .. key

    shdict:delete(key)
    shdict:delete(vkey)
end

return _M