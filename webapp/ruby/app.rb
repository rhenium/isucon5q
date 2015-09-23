require 'sinatra/base'
require 'digest/sha2'
require 'mysql2-cs-bind'
require 'rack-flash'
require 'json'
require "redis"

module Isucon4
  class App < Sinatra::Base
    use Rack::Session::Cookie, secret: ENV['ISU4_SESSION_SECRET'] || 'shirokane'
    use Rack::Flash

    helpers do
      def config
        @config ||= {
          user_lock_threshold: (ENV['ISU4_USER_LOCK_THRESHOLD'] || 3).to_i,
          ip_ban_threshold: (ENV['ISU4_IP_BAN_THRESHOLD'] || 10).to_i,
        }
      end

      def db
        Thread.current[:isu4_db] ||= Mysql2::Client.new(
          host: ENV['ISU4_DB_HOST'] || 'localhost',
          port: ENV['ISU4_DB_PORT'] ? ENV['ISU4_DB_PORT'].to_i : nil,
          username: ENV['ISU4_DB_USER'] || 'root',
          password: ENV['ISU4_DB_PASSWORD'],
          database: ENV['ISU4_DB_NAME'] || 'isu4_qualifier',
          reconnect: true,
        )
      end

      def redis
        Thread.current[:redis] ||= Redis.new(db: `id -u`.chomp[-1].to_i)
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def login_log(succeeded, user)
        if succeeded
          redis.zadd("locks", 0, user["login"])
          redis.zadd("bans", 0, request.ip)
        else
          redis.zincrby("locks", 1, user["login"]) if user
          redis.zincrby("bans", 1, request.ip)
        end
      end

      def user_locked?(user)
        return nil unless user
        config[:user_lock_threshold] <= redis.zscore("locks", user["login"]).to_i
      end

      def ip_banned?
        config[:ip_ban_threshold] <= redis.zscore("bans", request.ip).to_i
      end

      def attempt_login(login, password)
        user = db.xquery('SELECT * FROM users WHERE login = ?', login).first

        if ip_banned?
          login_log(false, user) # user may be nil
          return [nil, :banned]
        end

        if user_locked?(user)
          login_log(false, user)
          return [nil, :locked]
        end

        if user && calculate_password_hash(password, user['salt']) == user['password_hash']
          login_log(true, user)
          [user, nil]
        elsif user
          login_log(false, user)
          [nil, :wrong_password]
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

    get '/' do
      erb :index, layout: :base
    end

    post '/login' do
      user, err = attempt_login(params[:login], params[:password])
      if user
        lastca = redis.hget("lastca", user["id"])
        lastip = redis.hget("lastip", user["id"])
        session[:user_id] = user['id']
        session[:login] = user["login"]
        session[:last_created_at] = lastca || Time.now.strftime("%Y-%m-%d %H:%M:%S")
        session[:last_ip] = lastip || request.ip
        redis.hset("lastca", user["id"], Time.now.strftime("%Y-%m-%d %H:%M:%S"))
        redis.hset("lastip", user["id"], request.ip)
        redirect '/mypage'
      else
        case err
        when :locked
          flash[:notice] = "This account is locked."
        when :banned
          flash[:notice] = "You're banned."
        else
          flash[:notice] = "Wrong username or password"
        end
        redirect '/'
      end
    end

    get '/mypage' do
      unless session["user_id"]
        flash[:notice] = "You must be logged in"
        redirect '/'
      end
      erb :mypage, layout: :base
    end

    get '/report' do
      content_type :json
      {
        banned_ips: banned_ips,
        locked_users: locked_users,
      }.to_json
    end
  end
end
