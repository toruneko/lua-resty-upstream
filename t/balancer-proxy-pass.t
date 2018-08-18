
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (3 * blocks() + 7);

$ENV{TEST_NGINX_CWD} = cwd();

no_long_string();

our $HttpConfig = <<'_EOC_';
    lua_package_path '$TEST_NGINX_CWD/lib/?.lua;$TEST_NGINX_CWD/t/lib/?.lua;;';
    lua_shared_dict upstream  1m;
    init_by_lua_block {
        local upstream = require "ngx.upstream"
        upstream.init({
            cache = "upstream",
            cache_size = 10
        })
    }
    init_worker_by_lua_block {
        local upstream = require "ngx.upstream"
        upstream.update_upstream("foo.com", {
            version = 1,
            hosts = {
                {name = "a1.foo.com:8080", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 100, default_down = false},
                {name = "a2.foo.com:8080", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 100, default_down = false}
            }
        })
    }

    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504 http_403 http_404;
    proxy_next_upstream_tries 10;
    upstream dyups_server {
        server 0.0.0.0:80;
        balancer_by_lua_block {
            local balancer = require "resty.balancer"
            local ok, err = balancer.proxy_pass(ngx.ctx.balancer, ngx.ctx.tries)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
_EOC_

run_tests();

__DATA__

=== TEST 1: proxy pass without tries
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 0
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        return 200;
    }
--- request
GET /t
--- no_response_body
--- error_code: 200
--- no_error_log
[error]



=== TEST 2: proxy pass tries 3 times
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 3
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        content_by_lua_block {
            ngx.log(ngx.ERR, "enter backend")
            ngx.exit(500)
        }
    }
--- request
GET /t
--- response_body_like: 500 Internal Server Error
--- error_code: 500
--- grep_error_log eval: qr{enter backend}
--- grep_error_log_out
enter backend
enter backend
enter backend

--- no_error_log
[warn]



=== TEST 3: proxy pass tries 3 times when no max_fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 2,
                hosts = {
                    {
                        name = "a1.foo.com:8080",
                        host = "127.0.0.1",
                        port = $TEST_NGINX_SERVER_PORT,
                        weight = 100,
                        default_down = false,
                        max_fails = 0
                    },
                }
            })

            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 3
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        content_by_lua_block {
            ngx.log(ngx.ERR, "enter backend")
            ngx.exit(500)
        }
    }
--- request
GET /t
--- response_body_like: 500 Internal Server Error
--- error_code: 500
--- grep_error_log eval: qr{enter backend}
--- grep_error_log_out
enter backend
enter backend
enter backend
--- no_error_log
[warn]



=== TEST 4: proxy pass tries 4 times makes peer temporarily unavailable
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 2,
                hosts = {
                    {name = "a1.foo.com:8080", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 100, default_down = false},
                }
            })

            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 4
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        content_by_lua_block {
            ngx.log(ngx.ERR, "enter backend")
            ngx.exit(500)
        }
    }
--- request
GET /t
--- response_body_like: 502 Bad Gateway
--- error_code: 502
--- grep_error_log eval: qr{enter backend}
--- grep_error_log_out
enter backend
enter backend
enter backend
--- error_log
a1.foo.com:8080 temporarily unavailable
[warn]



=== TEST 5: proxy pass tries 3 times when one times max_fails
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local upstream = require "ngx.upstream"
            upstream.update_upstream("foo.com", {
                version = 2,
                hosts = {
                    {
                        name = "a1.foo.com:8080",
                        host = "127.0.0.1",
                        port = $TEST_NGINX_SERVER_PORT,
                        weight = 100,
                        default_down = false,
                        max_fails = 1
                    },
                }
            })

            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 3
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        content_by_lua_block {
            ngx.log(ngx.ERR, "enter backend")
            ngx.exit(500)
        }
    }
--- request
GET /t
--- response_body_like: 502 Bad Gateway
--- error_code: 502
--- error_log
enter backend
[error]
--- error_log
a1.foo.com:8080 temporarily unavailable
[warn]
--- error_log
no available peer: foo.com
[error]



=== TEST 6: peer temporarily unavailable timeout
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_by_lua_block {
            local init = ngx.req.get_uri_args()["init"]
            if init == "1" then
                local upstream = require "ngx.upstream"
                upstream.update_upstream("foo.com", {
                    version = 2,
                    hosts = {
                        {
                            name = "a1.foo.com:8080",
                            host = "127.0.0.1",
                            port = $TEST_NGINX_SERVER_PORT,
                            weight = 100,
                            default_down = false,
                            max_fails = 1,
                            fail_timeout = 1
                        },
                    }
                })
            else
                ngx.sleep(2)
            end

            local balancer = require "resty.balancer"
            ngx.ctx.balancer = function()
                return balancer.get_round_robin_peer("foo.com")
            end
            ngx.ctx.tries = 1
        }

        proxy_pass http://dyups_server/backend;
    }

    location = /backend {
        content_by_lua_block {
            ngx.print("entered backend")
        }
    }
--- pipelined_requests eval
["GET /t?init=1", "GET /t"]
--- response_body eval
["entered backend",
"entered backend"]
--- error_code eval
[200, 200]
--- no_error_log
[error]