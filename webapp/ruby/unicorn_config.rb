worker_processes 4
preload_app true
if ENV["USER"] == "isucon"
  pid "/home/isucon/webapp/ruby/unicorn.pid"
  listen "/tmp/unicorn.sock"
else
  listen "/tmp/#{ENV["HOME"]}.sock"
end
