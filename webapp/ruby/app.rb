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
        Thread.current[:redis] ||= Redis.new
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def login_log(succeeded, login, user_id = nil)
        if succeeded
          redis.zadd("locks", 0, user_id)
          redis.zadd("bans", 0, request.ip)
        else
          redis.zincrby("locks", 1, user_id) if user_id
          redis.zincrby("bans", 1, request.ip)
        end
        return
        db.xquery("INSERT INTO login_log" \
                  " (`created_at`, `user_id`, `login`, `ip`, `succeeded`)" \
                  " VALUES (?,?,?,?,?)",
                 Time.now, user_id, login, request.ip, succeeded ? 1 : 0)
      end

      def user_locked?(user)
        return nil unless user
        config[:user_lock_threshold] <= redis.zscore("locks", user["id"])
      end

      def ip_banned?
        config[:ip_ban_threshold] <= redis.zscore("bans", request.ip)
      end

      def attempt_login(login, password)
        user = db.xquery('SELECT * FROM users WHERE login = ?', login).first

        if ip_banned?
          login_log(false, login, user ? user['id'] : nil)
          return [nil, :banned]
        end

        if user_locked?(user)
          login_log(false, login, user['id'])
          return [nil, :locked]
        end

        if user && calculate_password_hash(password, user['salt']) == user['password_hash']
          login_log(true, login, user['id'])
          [user, nil]
        elsif user
          login_log(false, login, user['id'])
          [nil, :wrong_password]
        else
          login_log(false, login)
          [nil, :wrong_login]
        end
      end

      def current_user
        return @current_user if @current_user
        return nil unless session[:user_id]

        @current_user = db.xquery('SELECT * FROM users WHERE id = ?', session[:user_id].to_i).first
        unless @current_user
          session[:user_id] = nil
          return nil
        end

        @current_user
      end

      #def last_login
      #  return nil unless current_user

      #  db.xquery('SELECT * FROM login_log WHERE succeeded = 1 AND user_id = ? ORDER BY id DESC LIMIT 2', current_user['id']).each.last
      #end

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
      unless current_user
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
