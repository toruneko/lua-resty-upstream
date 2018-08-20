-- Copyright (C) by Jianhao Dai (Toruneko)

local upstream = require "resty.upstream"

package.loaded["ngx.upstream"] = setmetatable({}, { __index = upstream })

local ok, healthcheck = pcall(require, "resty.upstream.healthcheck")
if not ok then
    error("lua-resty-upstream-healthcheck module required")
end

return healthcheck