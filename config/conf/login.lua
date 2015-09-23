local login
local password
local ip = (ngx.req.get_headers().x_forwarded_for or ngx.req.get_headers().x_real_ip or ngx.var.remote_addr)

local args = ngx.req.get_post_args()
for key, val in pairs(args) do
  if key == "login" then
    login = val
  elseif key == "password" then
    password = val
  end
end

local resty_redis = require "resty.redis"
local redis = resty_redis:new()
redis:connect("127.0.0.1", 6379)

function login_fail(l)
  if l then
    redis:zincrby("locks", 1, login) end
  redis:zincrby("bans", 1, ip)
end

function login_success(user)
  redis:zadd("locks", 0, login)
  redis:zadd("bans", 0, ip)
  local uid = tostring(user["id"])
  local last_created_at = redis:hget("lastca", user["id"])
  if last_created_at == ngx.null then last_created_at = os.date("%Y-%m-%d %H:%M:%S") end
  local last_ip = redis:hget("lastip", user["id"])
  if last_ip == ngx.null then last_ip = ip end
  ngx.header["Set-Cookie"] = {"user_id="..uid, "login="..login, "last_created_at="..last_created_at, "last_ip="..last_ip }
  redis:hset("lastca", user["id"], last_created_at)
  redis:hset("lastip", user["id"], last_ip)
end

local juser = redis:hget("users", login)

local bans = redis:zscore("bans", ip)
if bans ~= ngx.null and tonumber(bans) >= 10 then
  if juser ~= ngx.null then login_fail(login) else login_fail(nil) end
  redis:set_keepalive(10000, 100)
  return ngx.redirect("/?notice=You%27re+banned.")
end

local resty_sha256 = require "resty.sha256"
local str = require "resty.string"
local sha256 = resty_sha256:new()
local cjson = require "cjson"
if juser ~= ngx.null then
  local locks = redis:zscore("locks", login)
  if locks ~= ngx.null and tonumber(locks) >= 3 then
    login_fail(login)
    redis:set_keepalive(10000, 100)
    return ngx.redirect("/?notice=This+account+is+locked.")
  end

  local user = cjson.decode(juser)
  sha256:update(password .. ":" .. user["salt"])
  if str.to_hex(sha256:final()) == user["hash"] then
    login_success(user)
    redis:set_keepalive(10000, 100)
    return ngx.redirect("/mypage")
  end
end

login_fail(login)
redis:set_keepalive(10000, 100)
return ngx.redirect("/?notice=Wrong+username+or+password")
