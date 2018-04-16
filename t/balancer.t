
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
    init_worker_by_lua_block {
        local upstream = require "ngx.upstream"
        upstream.update_upstream("foo.com", {
            version = 1,
            hosts = {
                {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 100, default_down = false},
                {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 100, default_down = false}
            }
        })
    }
_EOC_

run_tests();

__DATA__



=== TEST 4: get weighted round robin peer when no peer available
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local upstream = require "ngx.upstream"
            local ok = upstream.update_upstream("foo.com", {
                version = 2,
                hosts = {
                    {name = "a1.foo.com:8080", host = "a1.foo.com", port = 8080, weight = 50, default_down = false},
                    {name = "a2.foo.com:8080", host = "a2.foo.com", port = 8080, weight = 75, default_down = false}
                }
            })
            if not ok then
                ngx.log(ngx.ERR, "update upstream failed")
            end
            upstream.set_peer_down("foo.com", false, "a1.foo.com:8080", true)
            upstream.set_peer_down("foo.com", false, "a2.foo.com:8080", true)
        }
        content_by_lua_block {
            local balancer = require "resty.balancer"
            local peer, err = balancer.get_weighted_round_robin_peer("foo.com")
            if not peer then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- no_response_body
--- error_code: 200
--- error_log
no available peer
[error]

