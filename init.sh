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

#mysql -uisucon isucon <<'EOF'
#create table locks (
#id int(11) not null,
#primary key (id)
#);
#
#create table bans (
#ip varchar(16) not null,
#primary key (ip)
#);
#EOF

ruby <<'EOF'
require "mysql2"
require "redis"

mysql = Mysql2::Client.new(host: "localhost", username: "isucon", password: "isucon", database: "isu4_qualifier")
redis = Redis.new(db: `id -u`.to_i)
redis.flushdb

locks = Hash.new(0)
bans = Hash.new(0)

mysql.query("select * from login_log").each do |row|
  if row["succeeded"] == 0
    bans[row["ip"]] += 1
    if row["user_id"]
      locks[row["user_id"]] += 1
    end
  else
    locks[row["user_id"]] = 0
    bans[row["ip"]] = 0
  end
end

locks.each do |id, val|
  redis.zadd("locks", val, id)
end

bans.each do |ip, val|
  redis.zadd("bans", val, ip)
end

EOF
#echo "flush_all" | nc localhost 11211
