# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 2 + 1);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
    lua_shared_dict upstream  5m;
    init_by_lua_block {
        local upstream = require "resty.upstream"
        upstream.init({
            cache = "upstream",
            cache_size = 1000
        })
    }
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: health check (good case), status ignored by default
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
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
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict monitor 1m;
init_worker_by_lua '
    local upstream = require "resty.upstream"
    local ok = upstream.update_upstream("foo.com", {
        version = 1,
        hosts = {
            {name = "127.0.0.1:12354", host = "127.0.0.1", port = 12354, weight = 100, default_down = false},
            {name = "127.0.0.1:12355", host = "127.0.0.1", port = 12355, weight = 100, default_down = false},
            {name = "127.0.0.1:12356", host = "127.0.0.1", port = 12356, weight = 100, default_down = false}
        }
    })
    if not ok then
        ngx.log(ngx.ERR, "update upstream failed")
    end

    ngx.shared.monitor:flush_all()
    local hc = require "resty.upstream.monitor"
    local ok, err = hc.spawn_checker{
        shm = "monitor",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local hc = require "resty.upstream.monitor"
            ngx.print(hc.status_page("monitor"))

            ngx.sleep(0.52)

            for i = 1, 3 do
                local res = ngx.location.capture("/proxy")
                ngx.say("upstream addr: ", res.header["X-Foo"])
            end
        ';
    }

    location = /proxy {
        proxy_pass http://foo.com/;
        header_filter_by_lua '
            ngx.header["X-Foo"] = ngx.var.upstream_addr;
        ';
    }
--- request
GET /t

--- response_body
foo.com,127.0.0.1:12354,100,up,1,0,1,0
foo.com,127.0.0.1:12356,100,up,1,0,1,0
foo.com,127.0.0.1:12355,100,up,1,0,1,0
upstream addr: 127.0.0.1:12356
upstream addr: 127.0.0.1:12355
upstream addr: 127.0.0.1:12354

--- no_error_log
[error]