
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (3 * blocks());

$ENV{TEST_NGINX_CWD} = cwd();

no_long_string();

our $HttpConfig = <<'_EOC_';
    lua_package_path '$TEST_NGINX_CWD/lib/?.lua;$TEST_NGINX_CWD/t/lib/?.lua;;';
    lua_shared_dict upstream  5m;
    init_by_lua_block {
        local upstream = require "ngx.upstream"
        upstream.init({
            cache = "upstream",
            cache_size = 1000
        })
    }
_EOC_

run_tests();

__DATA__

=== TEST 1: update upstream
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            local ok = upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
--- error_code: 200
--- no_error_log
[error]



=== TEST 2: get upstreams
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            upstream.update_upstream("bar.com", {
                version = 1,
                hosts = {
                    {name = "a1.bar.com:8080", host = "a1.bar.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.bar.com:8080", host = "a2.bar.com", port = 8080, weight = 100, default_down = false}
                }
            })
            local ups = upstream.get_upstreams()
            table.sort(ups)
            for _, up in ipairs(ups) do
                ngx.say(up)
            end
        }
    }
--- request
GET /t
--- response_body
bar.com
foo.com
--- error_code: 200
--- no_error_log
[error]



=== TEST 3: delete upstreams
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host="a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host="a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            upstream.update_upstream("bar.com", {
                version = 1,
                hosts = {
                    {name = "a1.bar.com:8080", host="a1.bar.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.bar.com:8080", host="a2.bar.com", port = 8080, weight = 100, default_down = false}
                }
            })
            upstream.delete_upstream("foo.com")
            local ups = upstream.get_upstreams()
            for _, up in ipairs(ups) do
                ngx.say(up)
            end
        }
    }
--- request
GET /t
--- response_body
bar.com
--- error_code: 200
--- no_error_log
[error]



=== TEST 4: get upstream
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            upstream.update_upstream("bar.com", {
                version = 1,
                hosts = {
                    {name = "a1.bar.com:8080", host = "a1.bar.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.bar.com:8080", host = "a2.bar.com", port = 8080, weight = 100, default_down = false}
                }
            })
            local ups = upstream.get_upstreams()
            table.sort(ups)
            for _, up in ipairs(ups) do
                local u, err = upstream.get_upstream(up)
                if not u then
                    ngx.log(ngx.ERR, err)
                end
                for _, peer in ipairs(u.peers) do
                    ngx.say(peer.host)
                end
            end
        }
    }
--- request
GET /t
--- response_body
a1.bar.com
a2.bar.com
a1.foo.com
a2.foo.com
--- error_code: 200
--- no_error_log
[error]



=== TEST 5: set peer down
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            local ups = upstream.get_upstream("foo.com")
            upstream.set_peer_down("foo.com", false, "a2.foo.com:8080", false)
            ngx.say(ups.peers[2].down)

            upstream.set_peer_down("foo.com", false, "a2.foo.com:8080", true)
            local ups = upstream.get_upstream("foo.com")
            ngx.say(ups.peers[2].down)
        }
    }
--- request
GET /t
--- response_body
false
true
--- error_code: 200
--- no_error_log
[error]



=== TEST 6: get primary peers
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 1,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            local peers = upstream.get_primary_peers("foo.com")
            ngx.say(#peers)

        }
    }
--- request
GET /t
--- response_body
2
--- error_code: 200
--- no_error_log
[error]



=== TEST 7: get version
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 100,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
                }
            })
            local version = upstream.get_version("foo.com")
            ngx.say(version)

        }
    }
--- request
GET /t
--- response_body
100
--- error_code: 200
--- no_error_log
[error]
