Name
=============

lua-resty-upstream-balancer - pure lua server balancer module

Status
======

This library is considered production ready.

Build status: [![Travis](https://travis-ci.org/toruneko/lua-resty-upstream.svg?branch=master)](https://travis-ci.org/toruneko/lua-resty-upstream)

Description
===========

This library requires an nginx build with [ngx_lua module](https://github.com/openresty/lua-nginx-module), and [LuaJIT 2.0](http://luajit.org/luajit.html).

Synopsis
========

```lua
    # nginx.conf:

    lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";
    lua_shared_dict upstream    1m;
    lua_shared_dict healthcheck 1m;
    
    server {
        location = /t {

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

```lua
    # nginx.conf:

    lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";
    lua_shared_dict upstream    1m;
    lua_shared_dict healthcheck 1m;
    
    server {
        location = /t {

            balancer_by_lua_block {
                -- resty.balancer extend ngx.balancer
                -- use resty.balancer instead of ngx.balanacer 
                -- the peer_factory like:
                -- local peer_factory = function(u)
                --    return balancer.get_round_robin_peer(u)
                -- end

                local balancer = require "resty.balancer"
                local ok, err = balancer.proxy_pass(peer_factory, "foo.com", 3, false)
                if not ok then
                    ngx.log(ngx.ERR, err)
                end
                ngx.exit(502)
            }
        }
    }
```

Methods
=======

To load this library,

1. you need to specify this library's path in ngx_lua's [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive. For example, `lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";`.
2. you use `require` to load the library into a local Lua variable:

```lua
    local balancer = require "resty.balancer"
```

proxy_pass
---
`syntax: ok, err = balancer.proxy_pass(peer_factory, u, tries?, include?)`

`phase: balancer_by_lua`

do proxy pass considered `max_fails` and `fail_timeout` options from parent module `lua-resty-upstream`

The optional `peer_factory` argument specifies a peer factory function. The factory function has only one argument which means upstream name, and returns two values:

- `peer`: the upstream peer for current request.
- `err`: textual error message

```lua
local peer_factory = function(u)
    return balancer.get_round_robin_peer(u)
end
```

The optional `u` argument specifies upstream name for current request.

The optional `tries` argument specifies tries performed when the current attempt fails. You can see `ngx.balancer` document for more infomations. By default, the argument is set to `0`.

The optional `inlcude` argument specifies the last one attempt should be considered for `max_fails` or not. By default, the argument is set to `false`.

if considered last one attempt(which is fails), `balancer.proxy_pass` will be returns an error message `max tries`.

if not considered, proxy pass the request, and response to client.

```lua
local ok, err = balancer.proxy_pass(peer_factory, u)
if not ok then
    ngx.log(ngx.ERR, err)
end
ngx.exit(502)
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
-- balancer_by_lua phase support only
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
-- balancer_by_lua phase support only
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
-- balancer_by_lua phase support only
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
