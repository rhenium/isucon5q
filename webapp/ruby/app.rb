require 'sinatra/base'
require "sinatra/cookies"
require 'digest/sha2'
require "redis"
require "json"

module Isucon4
  class App < Sinatra::Base
    helpers Sinatra::Cookies
    set :cookie_options, domain: nil

    helpers do
      def config
        @config ||= {
          user_lock_threshold: (ENV['ISU4_USER_LOCK_THRESHOLD'] || 3).to_i,
          ip_ban_threshold: (ENV['ISU4_IP_BAN_THRESHOLD'] || 10).to_i,
        }
      end

      def redis
        Thread.current[:redis] ||= Redis.new(db: `id -u`.chomp[-1].to_i)
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def login_log(succeeded, login)
        if succeeded
          redis.zadd("locks", 0, login)
          redis.zadd("bans", 0, request.ip)
        else
          redis.zincrby("locks", 1, login) if login
          redis.zincrby("bans", 1, request.ip)
        end
      end

      def user_locked?(login)
        config[:user_lock_threshold] <= redis.zscore("locks", login).to_i
      end

      def ip_banned?
        config[:ip_ban_threshold] <= redis.zscore("bans", request.ip).to_i
      end

      def attempt_login(login, password)
        j = redis.hget("users", login)

        if ip_banned?
          login_log(false, j && login) # user may be nil
          return [nil, :banned]
        end

        if j
          if user_locked?(login)
            login_log(false, login)
            return [nil, :locked]
          end

          user = JSON.parse(j)
          if calculate_password_hash(password, user['salt']) == user['hash']
            login_log(true, login)
            [user, nil]
          else
            login_log(false, login)
            [nil, :wrong_password]
          end
        else
          login_log(false, nil)
          [nil, :wrong_login]
        end
      end

      def banned_ips
        redis.zrangebyscore("bans", config[:ip_ban_threshold], "+inf")
      end

      def locked_users
        redis.zrangebyscore("locks", config[:user_lock_threshold], "+inf")
      end
    end

    post '/login' do
      user, err = attempt_login(params[:login], params[:password])
      if user
        lastca = redis.hget("lastca", user["id"])
        lastip = redis.hget("lastip", user["id"])
        cookies[:user_id] = user['id']
        cookies[:login] = params[:login]
        cookies[:last_created_at] = lastca || Time.now.strftime("%Y-%m-%d %H:%M:%S")
        cookies[:last_ip] = lastip || request.ip
        redis.hset("lastca", user["id"], Time.now.strftime("%Y-%m-%d %H:%M:%S"))
        redis.hset("lastip", user["id"], request.ip)
        redirect '/mypage'
      else
        case err
        when :locked
          redirect "/?notice=This+account+is+locked."
        when :banned
          redirect "/?notice=You%27re+banned."
        else
          redirect "/?notice=Wrong+username+or+password"
        end
      end
    end

    get '/report' do
      content_type :json
      JSON.generate(banned_ips: banned_ips,
                    locked_users: locked_users)
    end
  end
end
