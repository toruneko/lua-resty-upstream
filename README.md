# lua-resty-upstream

Pure Lua dynamic upstream management for OpenResty / LuaJIT.

[![Travis](https://travis-ci.org/toruneko/lua-resty-upstream.svg?branch=master)](https://travis-ci.org/toruneko/lua-resty-upstream)

## Status

This library is considered production ready.

## Description

`lua-resty-upstream` manages Nginx upstream groups entirely in Lua, without
requiring an Nginx reload. It provides three modules:

| Module | Purpose |
| --- | --- |
| `resty.upstream` | Definition and storage of upstream peers |
| `resty.upstream.balancer` | Peer selection (round robin, weighted round robin, source IP hash) and retry handling |
| `resty.upstream.monitor` | Active HTTP health checks that mark peers up/down |

Upstream definitions and peer state are stored in shared memory, so every
worker process sees the same data and updates take effect immediately.

## Requirements

- An Nginx build with [ngx_lua](https://github.com/openresty/lua-nginx-module)
  (OpenResty is recommended) and LuaJIT 2.0+
- `ngx.balancer` support for `balancer_by_lua_block`

## Dependencies

- [lua-resty-core](https://github.com/openresty/lua-resty-core) (for
  `resty.core.shdict` on ngx_lua >= 0.10.12)
- [lua-resty-lrucache](https://github.com/openresty/lua-resty-lrucache)
- [lua-resty-iputils](https://github.com/hamishforbes/lua-resty-iputils)
- [lua-resty-http](https://github.com/pintsized/lua-resty-http) — optional,
  only needed when `http_req` is a table

## Installation

Copy `lib/resty` into a directory reachable through `lua_package_path`:

```bash
make install LUA_LIB_DIR=/usr/local/openresty/lualib
```

Or copy the files manually:

```bash
cp -r lib/resty/* /path/to/lualib/resty/
```

Then point `lua_package_path` at the parent of `resty/`.

## Synopsis

```nginx
# nginx.conf
lua_package_path "/path/to/lua-resty-upstream/lib/?.lua;;";

lua_shared_dict upstream 1m;  # upstream definitions and peer state
lua_shared_dict monitor  1m;  # health check state

init_by_lua_block {
    if ngx.config.ngx_lua_version >= 10012 then
        require "resty.core.shdict"
    end

    local upstream = require "resty.upstream"
    upstream.init({
        cache = "upstream",
        cache_size = 1000
    })
}

upstream foo.com {
    # a placeholder server; the real peers are chosen at runtime
    server 0.0.0.0;
    balancer_by_lua_block {
        local balancer = require "resty.upstream.balancer"
        local peer, err = balancer.get_weighted_round_robin_peer("foo.com")
        if not peer then
            error(err)
        end
        balancer.set_current_peer(peer.host, peer.port)
    }
}

server {
    listen 80;

    location / {
        proxy_pass http://foo.com;
    }
}

init_worker_by_lua_block {
    local upstream = require "resty.upstream"

    local ok, err = upstream.update_upstream("foo.com", {
        version = 1,
        hosts = {
            {
                name = "127.0.0.1:8080",  -- required, unique per upstream
                host = "127.0.0.1",       -- required
                port = 8080,
                weight = 100,
                max_fails = 3,
                fail_timeout = 10,        -- seconds
                default_down = false
            }
        }
    })
    if not ok then
        ngx.log(ngx.ERR, "failed to update upstream: ", err)
        return
    end

    local monitor = require "resty.upstream.monitor"
    local ok, err = monitor.spawn_checker({
        shm = "monitor",
        upstream = "foo.com",
        type = "http",
        -- raw HTTP request as a string (no lua-resty-http required)
        http_req = "HEAD /status HTTP/1.0\r\nHost: foo.com\r\n\r\n",
        -- or a table, which requires lua-resty-http:
        -- http_req = {
        --     method = "HEAD",
        --     path = "/status",
        --     headers = { Host = "foo.com" }
        -- },
        interval = 2000,           -- milliseconds
        timeout = 1000,            -- milliseconds
        fall = 3,                  -- failures before marking down
        rise = 2,                  -- successes before marking up
        valid_statuses = { 200, 302 },
        concurrency = 10
    })
    if not ok then
        upstream.delete_upstream("foo.com")
        ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
    end
}
```

## API

### resty.upstream

```lua
local upstream = require "resty.upstream"
```

#### init

`syntax: upstream.init(config)`

`phase: init_by_lua*`

Initializes the module and must be called exactly once per worker. Required
`config` fields:

- `cache`: the name of a `lua_shared_dict` used to store upstream data.
- `cache_size`: optional, the maximum number of upstream groups kept in the
  LRU cache (default `1000`). When the limit is exceeded, the least recently
  used upstream is evicted.

```lua
upstream.init({
    cache = "upstream",
    cache_size = 1000
})
```

#### update_upstream

`syntax: ok = upstream.update_upstream(u, data)`

`phase: init_worker_by_lua*, rewrite_by_lua*, access_by_lua*, content_by_lua*`

Creates or replaces the upstream named `u`. Returns `true` on success.

`data` fields:

- `version`: integer. It is used by the monitor to detect updates. Increment it
  whenever the peer list changes.
- `hosts`: array of peer tables.

```lua
local ok = upstream.update_upstream("foo.com", {
    version = 2,
    hosts = {
        {
            name = "127.0.0.1:8080", -- required, unique identity
            host = "127.0.0.1",      -- required
            port = 8080,             -- default 8080
            weight = 100,            -- default 100
            max_fails = 3,           -- default 3
            fail_timeout = 10,       -- default 10, in seconds
            default_down = false     -- default false
        }
    }
})
```

`weight`, `max_fails` and `fail_timeout` are used by
[resty.upstream.balancer](#restyupstreambalancer); `default_down` is used by
[resty.upstream.monitor](#restyupstreammonitor). Peers missing `name` or `host`
are silently skipped.

#### delete_upstream

`syntax: upstream.delete_upstream(u)`

`phase: init_worker_by_lua*, rewrite_by_lua*, access_by_lua*, content_by_lua*`

Deletes the upstream named `u` and its cached peer state.

#### get_upstream

`syntax: ups, err = upstream.get_upstream(u)`

Returns the internal upstream record (with `peers`, `version`, `size`, `cp`,
`cw`, `gcd`, `max` fields), or `nil` plus an error message.

#### get_upstreams

`syntax: names = upstream.get_upstreams()`

Returns an array of all upstream names.

#### get_primary_peers / get_backup_peers

`syntax: peers, err = upstream.get_primary_peers(u)`

`syntax: peers, err = upstream.get_backup_peers(u)`

Returns the peer arrays for the upstream `u`. Backup peers are not implemented
yet and always return an empty array.

#### get_version / get_peers_size

`syntax: version, err = upstream.get_version(u)`

`syntax: size, err = upstream.get_peers_size(u)`

Returns the `version` and peer count of the upstream `u`.

#### set_peer_down

`syntax: ok, err = upstream.set_peer_down(u, is_backup, name, value)`

Sets the persisted down state of peer `name`. Pass `true` to mark it down and
`nil` to mark it up. `is_backup` is currently always `false`.

#### check_peer_down

`syntax: down = upstream.check_peer_down(u, is_backup, name)`

Returns `true` if the peer is marked down, either permanently (via
`set_peer_down`) or temporarily (via `set_peer_temporarily_down`).

#### incr_peer_fails

`syntax: fails = upstream.incr_peer_fails(u, is_backup, name, timeout)`

Increments and returns the failure counter for peer `name`. The counter expires
after `timeout` seconds.

#### set_peer_temporarily_down

`syntax: ok, err = upstream.set_peer_temporarily_down(u, is_backup, name, timeout)`

Marks peer `name` down for `timeout` seconds. Used by the balancer when
`max_fails` is reached.

### resty.upstream.balancer

```lua
local balancer = require "resty.upstream.balancer"
```

The module forwards every method of `ngx.balancer`, so you can call
`balancer.set_current_peer(...)`, `balancer.set_more_tries(...)`, etc.

#### get_round_robin_peer

`syntax: peer, err = balancer.get_round_robin_peer(u)`

`phase: rewrite_by_lua*, access_by_lua*, balancer_by_lua*`

Returns the next available peer in simple round-robin order. Down peers are
skipped.

#### get_weighted_round_robin_peer

`syntax: peer, err = balancer.get_weighted_round_robin_peer(u)`

`phase: rewrite_by_lua*, access_by_lua*, balancer_by_lua*`

Returns the next peer using smooth weighted round-robin based on each peer's
`weight`.

#### get_source_ip_hash_peer

`syntax: peer, err = balancer.get_source_ip_hash_peer(u)`

`phase: rewrite_by_lua*, access_by_lua*, balancer_by_lua*`

Selects a peer by hashing `ngx.var.remote_addr`. Falls back to round robin if
the selected peer is down.

```lua
local peer, err = balancer.get_weighted_round_robin_peer("foo.com")
if not peer then
    ngx.log(ngx.ERR, err)
    return ngx.exit(502)
end
balancer.set_current_peer(peer.host, peer.port)
```

#### proxy_pass

`syntax: ok, err = balancer.proxy_pass(peer_factory, u, tries?, include?)`

`phase: balancer_by_lua*`

Selects a peer and sets it as the current peer, honoring `max_fails` and
`fail_timeout`. `peer_factory` is a function that takes the upstream name and
returns a peer:

```lua
local peer_factory = function(u)
    return balancer.get_round_robin_peer(u)
end
```

- `tries`: maximum number of attempts (default `0`).
- `include`: whether the last failed attempt counts towards `max_fails`
  (default `false`).

When retries are exhausted and the last failure is counted, it returns
`nil, "max tries"`; otherwise the request is proxied and the response is
returned to the client.

```lua
local ok, err = balancer.proxy_pass(peer_factory, "foo.com", 3, false)
if not ok then
    ngx.log(ngx.ERR, err)
    return ngx.exit(502)
end
```

### resty.upstream.monitor

```lua
local monitor = require "resty.upstream.monitor"
```

Forked from
[lua-resty-upstream-healthcheck](https://github.com/openresty/lua-resty-upstream-healthcheck).

#### spawn_checker

`syntax: ok, err = monitor.spawn_checker(opts)`

`phase: init_worker_by_lua*` (or later — it creates a timer)

Starts a background health checker for one upstream. Options:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `shm` | string | required | shared dict for health check state |
| `upstream` | string | required | upstream name to check |
| `type` | string | required | only `"http"` is supported |
| `http_req` | string or table | required | raw request, or a request table (requires lua-resty-http) |
| `interval` | number | `1000` | check interval in milliseconds |
| `timeout` | number | `1000` | connect/read timeout in milliseconds |
| `fall` | number | `5` | consecutive failures before marking a peer down |
| `rise` | number | `2` | consecutive successes before marking a peer up |
| `valid_statuses` | table | none | accepted status codes; any status is accepted when omitted |
| `concurrency` | number | `1` | number of concurrent checks |

The checker must be started after `upstream.init` and after the upstream has
been created with `update_upstream`.

#### kill_checker

`syntax: monitor.kill_checker(u)`

Stops the health checker for upstream `u`.

#### status_page

`syntax: body = monitor.status_page(shm)`

Returns a comma-separated status report for all known upstreams, in the form:

```
upstream,peer,weight,status,version,checker_version,ok_count,fail_count
```

Suitable for exposing from a `content_by_lua_block` endpoint.

## Development

Run the test suite with [Test::Nginx](https://github.com/openresty/test-nginx):

```bash
make test
```

The default OpenResty prefix is `/usr/local/openresty-debug`; override it with
`OPENRESTY_PREFIX`.

## Author

Jianhao Dai (toruneko) <toruneko@outlook.com>

## License

MIT License

Copyright (c) 2018 toruneko

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## See Also

- [lua-nginx-module](https://github.com/openresty/lua-nginx-module)
- [lua-resty-upstream-healthcheck](https://github.com/openresty/lua-resty-upstream-healthcheck)
- [lua-resty-upstream-balancer](lib/resty/upstream/balancer.md)
- [lua-resty-upstream-monitor](lib/resty/upstream/monitor.md)
