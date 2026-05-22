-- config.local.example.lua
-- Copy this file to config.local.lua to override configurations for your environment.
-- This file is ignored by Git, so your custom configurations will not be overwritten.

local local_config = {
  -- Paths configuration
  paths = {
    -- Override the data directory to use mounted storage (e.g. Google Drive rclone mount)
    -- On Linux server (mounted via rclone_mount.sh):
    -- data = "/mnt/osu_data",
    
    -- On Windows server (mounted via rclone_mount.bat):
    -- data = "R:/ayanomibancho-data",
    
    -- Default is "./data"
    data = "./data",
  },

  -- You can also override other configurations here if needed, for example:
  -- server = {
  --   port = 13380,
  -- },
  -- database = {
  --   driver = "sqlite",
  --   sqlite_path = "ayanomibancho.db",
  -- }
  -- Cloudflare Turnstile CAPTCHA keys
  -- Get keys from: https://dash.cloudflare.com/?to=/:account/turnstile
  -- turnstile = {
  --   site_key = "0x4AAAAAAA...",
  --   secret_key = "0x4AAAAAAA...",
  -- },
}

return local_config
