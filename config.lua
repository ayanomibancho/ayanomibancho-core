-- config.lua
-- Configuration settings for the osu! private server Luvit web backend

local config = {
  -- Web Server Configurations
  server = {
    host = "0.0.0.0",
    port = 13380,
  },
  
  -- Database Configurations
  database = {
    -- Driver can be "sqlite", "mysql", or "mock"
    driver = "sqlite",
    
    -- SQLite Configurations
    sqlite_path = "ayanomibancho.db",

    -- MySQL Configurations (Async MySQL Connection)
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "",
    database = "ayanomibancho",
  },
  
  -- Paths for Static Files and View Templates
  paths = {
    templates = "./views",
    public = "./public",
    data = "./data",  -- Data directory (avatars, beatmaps, replays, wallpaper, welcome)
                      -- On Linux server: "/mnt/osu_data" (rclone mount ayanomibancho)
  },

  -- Cloudflare Turnstile Configuration (CAPTCHA)
  -- Get keys from https://dash.cloudflare.com/?to=/:account/turnstile
  -- Override these in config.local.lua with your actual keys
  turnstile = {
    site_key = "",    -- Public site key (used in HTML widget)
    secret_key = "",  -- Private secret key (used for server-side verification)
  }
}

-- Load local config override if it exists (e.g. config.local.lua)
local fs = require('fs')
if fs.existsSync("config.local.lua") then
  local success, local_config = pcall(require, "./config.local")
  if success and type(local_config) == "table" then
    local function merge(t1, t2)
      for k, v in pairs(t2) do
        if type(v) == "table" and type(t1[k]) == "table" then
          merge(t1[k], v)
        else
          t1[k] = v
        end
      end
    end
    merge(config, local_config)
  else
    print("[Config Warning] Failed to load config.local.lua: ", local_config)
  end
end

return config
