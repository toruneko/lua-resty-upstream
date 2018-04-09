-- Copyright (C) by Jianhao Dai (Toruneko)

local cjson = require "cjson.safe"
local lrucache = require "resty.lrucache"

local _M = {
    _VERSION = '0.01'
}

-- init_by_lua
function _M:new(shdict, size)
    if not size then
        size = 1000
    end

    self.cache = lrucache.new(size)
    self.shdict = shdict
end

function _M:get(key)
    local cache = self.cache
    local shdict = self.shdict
    local vkey = "v:" .. key

    local c = cache:get(key)
    -- 本地cache中没有缓存
    if not c then
        -- 从shared中读取，写回本地缓存
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
    -- shdict中没有版本数据，可能已经被删除（或者被淘汰）
    if not ver then
        return nil, "no version"
    end
    -- 判断cache与shdict中的数据版本是否一致
    if ver == c.ver then
        return c.data, c.ver
    end

    -- 数据已被某个worker更新了，需要重新写入本地缓存
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

function _M:set(key, value, ttl)
    local shdict = self.shdict
    local vkey = "v:" .. key

    -- 只需更新shdict，本地缓存在get时会更新
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

function _M:delete(key)
    local shdict = self.shdict
    local vkey = "v:" .. key

    shdict:delete(key)
    shdict:delete(vkey)
end

return _M