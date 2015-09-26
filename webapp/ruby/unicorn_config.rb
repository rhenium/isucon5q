worker_processes 10
preload_app true
if ENV["USER"] == "isucon"
  pid "/home/isucon/webapp/ruby/unicorn.pid"
  listen "/sock/unicorn.sock"
else
  listen "/sock/#{ENV["USER"]}.sock"
end
