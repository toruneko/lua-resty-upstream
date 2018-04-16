Name
=============

lua-resty-upstream - pure lua nginx upstream management

Status
======

This library is considered production ready.

Build status: [![Travis](https://travis-ci.org/toruneko/lua-resty-upstream.svg?branch=master)](https://travis-ci.org/toruneko/lua-resty-upstream)

Description
===========

This library requires an nginx build with [ngx_lua module](https://github.com/openresty/lua-nginx-module), and [LuaJIT 2.0](http://luajit.org/luajit.html).

Specially, you can not install nginx with module [lua-upstream-module](https://github.com/openresty/lua-upstream-nginx-module).

for example:
```text
    tar -xzvf openresty-VERSION.tar.gz
    cd openresty-VERSION
    ./configure --without-http_lua_upstream_module
    make
    make install
```

Because of lua-resty-module implements the interface of lua-upstream-module, you can use [lua-resty-healthcheck](https://github.com/openresty/lua-resty-upstream-healthcheck) to check upstream peer status.

Synopsis
========

```lua
    # nginx.conf:

    lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";
    lua_shared_dict upstream    5m;
    lua_shared_dict healthcheck 1m;
    
    server {
        location = /t {
            content_by_lua_block {
                local upstream = require "ngx.upstream"
                upstream.init({
                    cache = "upstream",
                    cache_size = 1000
                })
                -- update foo.com upstream
                local ok = upstream.update_upstream("foo.com", {
                    version = 1,
                    hosts = {
                        {name = "127.0.0.1:8080", host = "127.0.0.1", port = 8080, weiht = 100, max_fails = 3, fail_timeout = 10, default_down = false}
                    }
                })
                if not ok then
                    return
                end
                -- if you installed healthcheck module. 
                -- https://github.com/openresty/lua-resty-upstream-healthcheck
                local healthcheck = require "resty.upstream.healthcheck"
                local ok, err = healthcheck.spawn_checker({
                    shm = "healthcheck",
                    upstream = "foo.com",
                    type = "http",
                    http_req = "GET /status HTTP/1.0\r\nHost: foo.com\r\n\r\n",
                    interval = 2000,
                    timeout = 1000,
                    fall = 3,
                    rise = 2,
                    valid_statuses = {200, 302},
                    concurrency = 10,
                })
                if not ok then
                    upstream.delete_upstream("foo.com")
                    ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
                    return
                end
                
               
            }
            
            balancer_by_lua_block {
                -- resty.balancer extend ngx.balancer
                -- use resty.balancer instead of ngx.balanacer 
                local balancer = require "resty.balancer"
                local peer, err = balancer.get_weighted_round_robin_peer("foo.com")
                if not peer then
                    ngx.log(ngx.ERR, err)
                end
                balancer.set_current_peer(peer.host, peer.port)
            }
        }
    }
    
```

upstream Methods
=======

To load this library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local upstream = require "ngx.upstream"
```

init
---
`syntax: upstream.init(config)`

`phase: init_by_lua`

initialize upstream management with configuration:

```nginx
lua_shared_dict upstream  10m;
```

```lua
local config = {
    cache = "upstream",
    cache_size = 1000
}
```

update_upstream
----
`syntax: ok = upstream.update_upstream(u, data)`

update upstream or create new upstream from data. return true on success.

```lua
local ok = upstream.update_upstream("foo.com", {
    version = 1,
    hosts = {
        {name = "127.0.0.1:8080", host = "127.0.0.1", port = 8080, weiht = 100, max_fails = 3, fail_timeout = 10, default_down = false}
    }
})
if not ok then
    return
end
```

max_fails, fail_timeout is not implement.

delete_upstream
------
`syntax: upstream:delete_upstream(u)`

delete upstream 

balancer Methods
=======

To load this library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local balancer = require "resty.balancer"
```

get_round_robin_peer
---
`syntax: peer, err = balancer.get_round_robin_peer(u)`

`phase: rewrite_by_lua, access_by_lua, balancer_by_lua`

```lua
local peer, err = balancer.get_round_robin_peer(u)
if not peer then 
    ngx.log(ngx.ERR, err)
end
balancer.set_current_peer(peer.host, peer.port)
```

get_source_ip_hash_peer
----
`syntax: peer, err = balancer.get_source_ip_hash_peer(u)`

`phase: rewrite_by_lua, access_by_lua, balancer_by_lua`

```lua
local peer, err = balancer.get_source_ip_hash_peer(u)
if not peer then 
    ngx.log(ngx.ERR, err)
end
balancer.set_current_peer(peer.host, peer.port)
```

get_weighted_round_robin_peer
------
`syntax: peer, err = balancer.get_weighted_round_robin_peer(u)`

`phase: rewrite_by_lua, access_by_lua, balancer_by_lua`

```lua
local peer, err = balancer.get_weighted_round_robin_peer(u)
if not peer then 
    ngx.log(ngx.ERR, err)
end
balancer.set_current_peer(peer.host, peer.port)
```

Author
======

Jianhao Dai (toruneko) <toruneko@outlook.com>


Copyright and License
=====================

This module is licensed under the MIT license.

Copyright (C) 2018, by Jianhao Dai (toruneko) <toruneko@outlook.com>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


See Also
========
* the ngx_lua module: https://github.com/openresty/lua-nginx-module