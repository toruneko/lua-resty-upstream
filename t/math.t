
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (3 * blocks());

$ENV{TEST_NGINX_CWD} = cwd();

no_long_string();

our $HttpConfig = <<'_EOC_';
    lua_package_path '$TEST_NGINX_CWD/lib/?.lua;;';
_EOC_

run_tests();

__DATA__

=== TEST 1: math gcd 100, 50
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            require "ngx.upstream.math"
            local math_gcd = math.gcd
            ngx.say(math_gcd(100, 50))
        }
    }
--- request
GET /t
--- response_body
50
--- error_code: 200
--- no_error_log
[error]


=== TEST 2: math gcd 100, 51
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            require "ngx.upstream.math"
            local math_gcd = math.gcd
            ngx.say(math_gcd(100, 51))
        }
    }
--- request
GET /t
--- response_body
1
--- error_code: 200
--- no_error_log
[error]
