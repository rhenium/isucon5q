threads 16, 16
workers 2
if ENV["USER"] == "isucon"
  bind "unix:///tmp/unicorn.sock"
else
  bind "unix://#{ENV["HOME"]}/unicorn.sock"
end
preload_app!
