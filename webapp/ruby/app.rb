require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'tilt/erubis'
require 'erubis'
require "oj"
require "redis"

module Isucon5
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
  class ContentNotFound < StandardError; end
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5::WebApp < Sinatra::Base
  use Rack::Session::Cookie
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)
  #set :sessions, true
  set :session_secret, ENV['ISUCON5_SESSION_SECRET'] || 'beermoris'
  set :protection, true

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'root',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5q',
        },
      }
    end

    def redis
      Thread.current[:redis] ||= Redis.new
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:isucon5_db] = client
      client
    end

    def authenticate(email, password)
      query = <<SQL
SELECT u.id AS user_id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
SQL
      result = db.xquery(query, email, password).first
      raise Isucon5::AuthenticationError unless result
      session[:user_id] = result[:user_id]
      session[:account_name] = result[:account_name]
      session[:nick_name] = result[:nick_name]
      session[:email] = result[:email]
      result
    end

    def myprofile
      if session[:profile]
        Oj.load(session[:profile])
      else
        profile = db.xquery('SELECT * FROM profiles WHERE user_id = ?', session[:user_id]).first
        if profile
          session[:profile] = Oj.dump(profile)
          profile
        else
          nil
        end
      end
    end

    def authenticated!
      redirect '/login' unless session[:user_id]
    end

    # from erb
    def get_user(user_id)
      user = db.xquery('SELECT * FROM users WHERE id = ?', user_id).first
      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_account(account_name)
      j = redis.hget("users", account_name)
      raise Isucon5::ContentNotFound unless j
      Oj.load(j).map {|k, v| [k.to_sym, v] }.to_h
    end

    def is_friend?(another_id)
      s, l = [another_id, session[:user_id]]
      redis.sismember("r#{s}", l)
    end

    def get_friends_map(id)
      friend_ids = get_friends_ids(id)
      qstr = "select another,created_at from relations where one = #{id} and another in (#{friend_ids.join(",")})"
      friends = db.query(qstr).map {|row| [row[:another], row[:created_at]] }
    end

    def get_friends_ids(id)
      redis.smembers("r#{id}")
    end

    def permitted?(another_id)
      another_id == session[:user_id] || is_friend?(another_id)
    end

    def mark_footprint(user_id)
      if user_id != session[:user_id]
        query = 'INSERT INTO footprints (user_id,owner_id) VALUES (?,?)'
        db.xquery(query, user_id, session[:user_id])
      end
    end

    PREFS = %w(
      未入力
      北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県
      石川県 福井県 山梨県 長野県 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県 鳥取県 島根県
      岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
    )
    def prefectures
      PREFS
    end
  end

  error Isucon5::AuthenticationError do
    session[:user_id] = nil
    session[:account_name] = nil
    halt 401, erubis(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Isucon5::PermissionDenied do
    halt 403, erubis(:error, locals: { message: '友人のみしかアクセスできません' })
  end

  error Isucon5::ContentNotFound do
    halt 404, erubis(:error, locals: { message: '要求されたコンテンツは存在しません' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: '高負荷に耐えられるSNSコミュニティサイトへようこそ!' }
  end

  post '/login' do
    authenticate params['email'], params['password']
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    authenticated!

    entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
    entries = db.xquery(entries_query, session[:user_id])
      .map{ |entry|
      entry[:is_private] = (entry[:private] == 1);
      entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
      entry }

    comments_for_me_query = <<SQL
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at, u.account_name AS account_name, u.nick_name AS nick_name
FROM comments c
JOIN users u ON u.id = c.user_id
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.created_at DESC
LIMIT 10
SQL
    comments_for_me = db.xquery(comments_for_me_query, session[:user_id])

    fids = get_friends_ids(session[:user_id])
    entries_of_friends = db.xquery(
      'SELECT entries.*,users.nick_name,users.account_name FROM entries JOIN users ON users.id = user_id WHERE user_id IN (?) ORDER BY created_at DESC LIMIT 10', fids.join(",")).map do |entry|
      entry[:title] = entry[:body].split(/\n/, 2).first
      entry
    end

    comments_of_friends = []
    db.query('SELECT comments.*,users.* FROM comments JOIN users ON users.id = comments.user_id ORDER BY comments.created_at DESC LIMIT 100').each do |comment|
      entry = db.xquery('SELECT private,user_id,account_name,nick_name FROM entries JOIN users ON users.id = user_id WHERE entries.id = ?', comment[:entry_id]).first
      entry[:is_private] = (entry[:private] == 1)
      next if entry[:is_private] && !permitted?(entry[:user_id])
      comment[:entry] = entry
      comments_of_friends << comment
      break if comments_of_friends.size >= 10
    end

    friends = get_friends_map(session[:user_id])

    footprints = get_footprints(10)

    locals = {
      profile: myprofile || {},
      entries: entries,
      comments_for_me: comments_for_me,
      entries_of_friends: entries_of_friends,
      comments_of_friends: comments_of_friends,
      friends: friends,
      footprints: footprints
    }
    erb :index, locals: locals
  end

  get '/profile/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    prof = myprofile
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :profile, locals: { owner: owner, profile: prof, entries: entries, private: permitted?(owner[:id]) }
  end

  post '/profile/:account_name' do
    authenticated!
    if params['account_name'] != session[:account_name]
      raise Isucon5::PermissionDenied
    end
    args = [params['first_name'], params['last_name'], params['sex'], params['birthday'], params['pref']]

    prof = myprofile
    if prof
      query = <<SQL
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
      args << session[:user_id]
    else
      query = <<SQL
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
      args.unshift(session[:user_id])
    end
    db.xquery(query, *args)
    session[:profile] = nil
    redirect "/profile/#{params['account_name']}"
  end

  get '/diary/entries/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20'
            end
    entries = db.xquery(query, owner[:id]).map{ |entry|
      entry[:is_private] = (entry[:private] == 1)
      entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
      entry[:cc] = redis.hget("comments", entry[:id]) || 0
      entry }
    mark_footprint(owner[:id])
    erb :entries, locals: { owner: owner,
                            entries: entries,
                            myself: (session[:user_id] == owner[:id]) }
  end

  get '/diary/entry/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT entries.*,users.nick_name AS nick_name FROM entries ' +
                      'JOIN users ON entries.user_id = users.id WHERE entries.id = ?', params['entry_id']).first
    raise Isucon5::ContentNotFound unless entry
    entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    comments = db.xquery('SELECT comments.*,users.nick_name,users.account_name FROM comments ' +
                         'JOIN users ON users.id = comments.user_id WHERE entry_id = ?', entry[:id])
    mark_footprint(entry[:user_id])
    erb :entry, locals: { owner: { nick_name: entry[:nick_name] },
                          entry: entry,
                          comments: comments }
  end

  post '/diary/entry' do
    authenticated!
    query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)'
    body = (params['title'] || "タイトルなし") + "\n" + params['content']
    db.xquery(query, session[:user_id], (params['private'] ? '1' : '0'), body)
    redirect "/diary/entries/#{session[:account_name]}"
  end

  post '/diary/comment/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    unless entry
      raise Isucon5::ContentNotFound
    end
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)'
    db.xquery(query, entry[:id], session[:user_id], params['comment'])
    redis.hincrby("comments", entry[:id], 1)
    redirect "/diary/entry/#{entry[:id]}"
  end

  def get_footprints(c)
    query = <<SQL
SELECT users.*,user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
FROM footprints
JOIN users ON owner_id = users.id
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
SQL
    db.xquery(query << " LIMIT #{c}", session[:user_id])
  end

  get '/footprints' do
    authenticated!
    footprints = get_footprints(50)
    erb :footprints, locals: { footprints: footprints }
  end

  get '/friends' do
    authenticated!
    list = get_friends_map(session[:user_id])
    erb :friends, locals: { friends: list }
  end

  post '/friends/:account_name' do
    authenticated!
    user = user_from_account(params['account_name'])
    unless is_friend?(user[:id])
      s, l = [session[:user_id], user[:id]].sort
      db.xquery('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', session[:user_id], user[:id], user[:id], session[:user_id])
      redis.sadd("r#{session[:user_id]}", user[:id])
      redis.sadd("r#{user[:id]}", session[:user_id])
      redirect '/friends'
    end
  end

  get '/initialize' do
    db.query("DELETE FROM relations WHERE id > 500000")
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")
    redis.flushdb
    ## users
    a = []
    db.query("select * from users", symbolize_keys: false).each_slice(100) do |row|
      row.each do |aa|
        a << aa["account_name"]
        a << Oj.dump(aa)
      end
      redis.hmset("users", a)
      a = []
    end

    ## relation
    a = Hash.new {|a, b| a[b] = [] }
    db.query("select * from relations").each do |row|
      s, l = [row[:one], row[:another]]
      a[s] << l
    end
    a.each do |k, vs|
      redis.sadd("r#{k}", vs)
    end

    ## comments
    a = []
    db.query("select count(*) AS c,entry_id from comments group by entry_id").each do |row|
      a << row[:entry_id]
      a << row[:c]
    end
    redis.hmset("comments", a)
    nil
  end
end
