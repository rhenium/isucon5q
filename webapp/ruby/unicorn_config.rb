worker_processes 10
preload_app true
if ENV["USER"] == "isucon"
  listen "/tmp/unicorn.sock"
else
  listen "#{ENV["HOME"]}/unicorn.sock"
end
