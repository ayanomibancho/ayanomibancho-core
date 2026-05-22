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
  }
}

return config
