#!/bin/sh
set -x
set -e
cd $(dirname $0)

myuser=root
mydb=isu4_qualifier
myhost=127.0.0.1
myport=3306
mysql -h ${myhost} -P ${myport} -u ${myuser} -e "DROP DATABASE IF EXISTS ${mydb}; CREATE DATABASE ${mydb}"
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < sql/schema.sql
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < sql/dummy_users.sql
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < sql/dummy_log.sql

ruby <<'EOF'
require "mysql2"
require "redis"
require "oj"

mysql = Mysql2::Client.new(host: "localhost", username: "isucon", password: "isucon", database: "isu4_qualifier")
redis = Redis.new
redis.flushdb
redis = Redis.new(db: `id -u #{ENV["USER"]}`.chomp[-1].to_i)
redis.flushdb

locks = Hash.new(0)
bans = Hash.new(0)

mysql.query("select * from login_log").each do |row|
  if row["succeeded"] == 0
    bans[row["ip"]] += 1
    if row["user_id"].to_i > 0
      locks[row["login"]] += 1
    end
  else
    locks[row["login"]] = 0
    bans[row["ip"]] = 0
  end
end

locks.each do |id, val|
  redis.zadd("locks", val, id)
end

bans.each do |ip, val|
  redis.zadd("bans", val, ip)
end

mysql.query("select * from users").each do |user|
  redis.hset("users", user["login"], Oj.dump("id" => user["id"],
                                             "hash" => user["password_hash"],
                                             "salt" => user["salt"]))
end

EOF
#echo "flush_all" | nc localhost 11211
