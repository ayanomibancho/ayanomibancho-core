-- main.lua
-- Main Server script for the osu! private server Luvit web backend

io.stdout:setvbuf('no')
io.stderr:setvbuf('no')

local http = require('http')
local url = require('url')
local config = require('./config')
local Router = require('./router')
local db = require('./db')
local template = require('./template')
local pagemappings = require('./pagemappings')

-- 1. Initialize Custom Router
local router = Router.new(config.paths.public)

-- 2. Import Route Handlers
local handleProfile = require('./handlers/profile')
local handleLeaderboard = require('./handlers/leaderboard')
local osuApi = require('./handlers/osu_api')
local v1Api = require('./handlers/v1_api')
local beatmapsHandler = require('./handlers/beatmaps')
local simple = require('./handlers/simple')
local handleAuth = require('./handlers/auth')
local session = require('./session')
local handleBancho = require('./handlers/bancho')

-- 2.5. Rate Limiting State and Helpers
local rateLimits = {}
local gcCounter = 0

local function getHeader(req, name)
  if not req.headers then return nil end
  local lowerName = name:lower()
  for _, pair in ipairs(req.headers) do
    if type(pair) == "table" and pair[1] and pair[1]:lower() == lowerName then
      return pair[2]
    end
  end
  return req.headers[lowerName] or req.headers[name]
end

local function getClientIp(req)
  local xff = getHeader(req, 'x-forwarded-for')
  if xff and xff ~= "" then
    local ip = string.match(xff, "^%s*([^,%s]+)")
    if ip then return ip end
  end

  local xri = getHeader(req, 'x-real-ip')
  if xri and xri ~= "" then
    return xri
  end

  if req.socket and req.socket.address then
    local ok, addr = pcall(req.socket.address, req.socket)
    if ok and addr and addr.ip then
      return addr.ip
    end
  end

  return "127.0.0.1"
end

local function shouldRateLimit(method, path)
  if not method or not path then return false end
  -- 1. Exclude static assets
  if string.match(path, "^/public/") then
    return false
  end
  -- 2. Exclude user avatar endpoints (GET /{user_id})
  if method == "GET" and string.match(path, "^/%d+$") then
    return false
  end
  -- 3. Exclude in-game Bancho connections (POST /)
  if method == "POST" and path == "/" then
    return false
  end
  -- 4. Exclude in-game endpoints (^/web/)
  if string.match(path, "^/web/") then
    return false
  end
  -- 5. Exclude beatmap downloads (^/d/)
  if string.match(path, "^/d/") then
    return false
  end
  
  return true
end

-- 3. Register HTTP Routes
-- GET: Home Page
router:get('^/$', function(req, res)
  local userCount = 0
  local scoreCount = 0
  
  -- Query counts from DB
  local stats = db.query("SELECT (SELECT COUNT(*) FROM users) as u_count, (SELECT COUNT(*) FROM scores) as s_count")
  if stats and stats[1] then
    userCount = stats[1].u_count or 0
    scoreCount = stats[1].s_count or 0
  end

  local function formatNumber(num)
    local formatted = tostring(num or 0)
    while true do
      local k
      formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
      if k == 0 then break end
    end
    return formatted
  end

  local dataContext = {
    title = "Home",
    total_users = formatNumber(userCount),
    total_scores = formatNumber(scoreCount)
  }
  local success, renderedHtml = pcall(template.render, "home", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Main] Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end)

-- GET: Global Leaderboard
router:get('^/leaderboard$', handleLeaderboard)

-- GET: Dynamic Player Profiles (/u/username)
-- Capture group matches username (characters, underscores, digits, spaces, and percent-encoding)
router:get('^/u/([%%%-%.%w_%%s]+)$', handleProfile)

-- GET: About, Team, and IRC pages (matching Ripple/Hanayo routes)
router:get('^/about$', simple.about)
router:get('^/team$', simple.team)
router:get('^/irc$', simple.irc)
router:post('^/irc/generate$', simple.ircGenerate)

-- GET & POST: User Authentication routes
router:get('^/login$', handleAuth.loginPage)
router:post('^/login$', handleAuth.loginSubmit)
router:get('^/register$', handleAuth.registerPage)
router:post('^/register$', handleAuth.registerSubmit)
router:get('^/logout$', handleAuth.logout)

-- GET & POST: Account Settings / Avatar Edit routes
router:get('^/home/account/edit$', handleAuth.editPage)
router:post('^/home/account/edit$', handleAuth.editSubmit)

-- GET & POST: Two-Factor Authentication routes
router:get('^/login/2fa$', handleAuth.login2faPage)
router:post('^/login/2fa$', handleAuth.login2faSubmit)
router:get('^/home/account/2fa/setup$', handleAuth.setup2faPage)
router:post('^/home/account/2fa/enable$', handleAuth.enable2faSubmit)
router:post('^/home/account/2fa/disable$', handleAuth.disable2faSubmit)

-- Legacy /settings redirects
router:get('^/settings/avatar$', function(req, res)
  res:writeHead(301, { ['Location'] = '/home/account/edit' })
  res:finish()
end)
router:get('^/settings$', function(req, res)
  res:writeHead(301, { ['Location'] = '/home/account/edit' })
  res:finish()
end)

-- POST: osu! client in-game registration
router:post('^/users$', handleAuth.registerClient)

-- GET: User profile by ID (redirect to /u/{username})
router:get('^/users/(%d+)$', function(req, res, captures)
  local userId = tonumber(captures[1])
  local users = db.query("SELECT username FROM users WHERE id = ?", userId)
  if users[1] then
    res:writeHead(302, {
      ['Location'] = '/u/' .. users[1].username,
      ['Content-Length'] = '0'
    })
    res:finish('')
  else
    local body = '404 Not Found'
    res:writeHead(404, {
      ['Content-Type'] = 'text/plain',
      ['Content-Length'] = tostring(#body)
    })
    res:finish(body)
  end
end)

-- GET & POST: osu! Scoreboard API endpoints
router:get('^/web/osu%-getscores%.php$', osuApi.getScores)
router:post('^/web/osu%-getscores%.php$', osuApi.getScores)
router:get('^/web/osu%-osz2%-getscores%.php$', osuApi.getScoresOsz2)
router:post('^/web/osu%-submit%-modular%-selector%.php$', osuApi.submitScore)
router:get('^/web/osu%-getreplay%.php$', osuApi.getReplay)
router:post('^/web/osu%-screenshot%.php$', osuApi.submitScreenshot)
router:post('^/web/osu%-submit%-beatmap%.php$', osuApi.submitBeatmap)

-- v1 API endpoints
router:get('^/api/v1/users/scores/best$', v1Api.getUserScoresBest)
router:get('^/api/v1/users/scores/recent$', v1Api.getUserScoresRecent)

-- Beatmap mirror endpoints (Cheesegull compatibility)
router:get('^/api/search$', beatmapsHandler.search)
router:get('^/api/b/(%d+)$', beatmapsHandler.getBeatmap)
router:get('^/api/s/(%d+)$', beatmapsHandler.getSet)
router:get('^/d/(%d+)[n]?$', beatmapsHandler.download)
router:head('^/d/(%d+)[n]?$', beatmapsHandler.download)

-- osu! client web API endpoints (required for login/gameplay)
router:get('^/web/bancho_connect%.php$', function(req, res)
  -- Returns empty response to indicate connection is OK
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

router:get('^/web/osu%-getfriends%.php$', function(req, res)
  -- Returns newline-delimited list of friend user IDs
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

router:get('^/web/osu%-getseasonal%.php$', function(req, res)
  -- Returns JSON array of seasonal background URLs
  local body = '[]'
  res:writeHead(200, {
    ['Content-Type'] = 'application/json',
    ['Content-Length'] = tostring(#body)
  })
  res:finish(body)
end)

router:get('^/web/lastfm%.php$', function(req, res)
  -- Anti-cheat / Last.fm scrobbling endpoint
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

router:get('^/web/osu%-markasread%.php$', function(req, res)
  -- Mark messages as read
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

router:post('^/web/osu%-getbeatmapinfo%.php$', function(req, res)
  -- Returns beatmap info, empty for now
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

router:get('^/web/check%-updates%.php$', function(req, res)
  -- Client update check, return empty = no updates
  local body = '[]'
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = tostring(#body)
  })
  res:finish(body)
end)

router:get('^/web/osu%-getfavourites%.php$', function(req, res)
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain',
    ['Content-Length'] = '0'
  })
  res:finish('')
end)

-- Avatar endpoint: GET /{user_id} (served from a.o.ayanomi.io.vn)
-- osu! client fetches avatars from https://a.ppy.sh/{user_id}
-- Avatar files stored as: data/avatars/{username}.png or .jpg
router:get('^/(%d+)$', function(req, res, captures)
  local userId = captures[1]
  local fs = require('fs')
  local db = require('./db')

  -- Look up username from DB
  local users = db.query("SELECT username FROM users WHERE id = ?", tonumber(userId))
  local username = users[1] and users[1].username or userId

  -- Helper to serve default avatar
  local function serveDefault()
    fs.readFile(config.paths.public .. "/avatar.jpg", function(err, data)
      if not err and data then
        res:writeHead(200, {
          ['Content-Type'] = 'image/jpeg',
          ['Content-Length'] = tostring(#data),
          ['Cache-Control'] = 'no-cache, no-store, must-revalidate'
        })
        res:finish(data)
      else
        res:writeHead(404, { ['Content-Type'] = 'text/plain', ['Content-Length'] = '0' })
        res:finish('')
      end
    end)
  end

  -- Try png first, then jpg, then default
  fs.readFile(config.paths.data .. "/avatars/" .. username .. ".png", function(err, data)
    if not err and data then
      res:writeHead(200, {
        ['Content-Type'] = 'image/png',
        ['Content-Length'] = tostring(#data),
        ['Cache-Control'] = 'no-cache, no-store, must-revalidate'
      })
      res:finish(data)
    else
      fs.readFile(config.paths.data .. "/avatars/" .. username .. ".jpg", function(err2, data2)
        if not err2 and data2 then
          res:writeHead(200, {
            ['Content-Type'] = 'image/jpeg',
            ['Content-Length'] = tostring(#data2),
            ['Cache-Control'] = 'no-cache, no-store, must-revalidate'
          })
          res:finish(data2)
        else
          serveDefault()
        end
      end)
    end
  end)
end)


-- POST: Bancho Connection Root
router:post('^/$', handleBancho.handle)

-- 4. Main Request Handler (Event Loop interface)
local function handleRequest(req, res)
  local parsedUrl = url.parse(req.url, true)
  local path = parsedUrl.pathname
  local method = req.method

  -- Rate Limiting: 30 requests per minute
  if shouldRateLimit(method, path) then
    local ip = getClientIp(req)
    local now = os.time()
    local limit = rateLimits[ip]

    if limit then
      if now - limit.startTime < 60 then
        if limit.count >= 30 then
          print(string.format('[Rate Limit] Blocked IP %s requesting %s %s', ip, method, path))
          res:writeHead(429, {
            ['Content-Type'] = 'text/plain',
            ['Retry-After'] = '60'
          })
          res:finish('429 Too Many Requests')
          return
        else
          limit.count = limit.count + 1
        end
      else
        limit.count = 1
        limit.startTime = now
      end
    else
      rateLimits[ip] = { count = 1, startTime = now }
    end

    -- Inline Garbage Collection
    gcCounter = gcCounter + 1
    if gcCounter % 100 == 0 then
      local expiry = now - 60
      for k, v in pairs(rateLimits) do
        if v.startTime < expiry then
          rateLimits[k] = nil
        end
      end
    end
  end

  -- Check legacy php or query-based redirections first
  if pagemappings.checkRedirect(req, res, path, parsedUrl.query) then
    return
  end


  -- Print simple access logs
  print(string.format('[%s] %s %s', os.date('%Y-%m-%d %H:%M:%S'), method, path))

  -- Check if request is targeting static assets (/public/...)
  local staticPath = string.match(path, "^/public/(.*)$")
  if staticPath then
    coroutine.wrap(function()
      local served = router:serveStatic(req, res, staticPath)
      if not served then
        res:writeHead(404, { ['Content-Type'] = 'text/html; charset=utf-8' })
        res:finish('<h1>404 File Not Found</h1><p>Static asset could not be found.</p>')
      end
    end)()
    return
  end

  -- Perform Dynamic Route Matching
  local handler, captures = router:match(method, path)
  if handler then
    -- Wrap route execution inside a coroutine to support non-blocking yields (e.g. DB calls)
    coroutine.wrap(function()
      local co = coroutine.running()
      
      -- Resolve session user and prepare user navigation bar block
      local currentUser = session.get(req)
      req.user = currentUser
      if currentUser then
        req.user_nav = string.format([[
          <a href="/u/%s" class="nav-link text-glow-teal">Profile (%s)</a>
          <a href="/home/account/edit" class="nav-link text-glow-teal">Settings</a>
          <a href="/logout" class="nav-link text-glow-pink">Logout</a>
        ]], currentUser.username, currentUser.username)
      else
        req.user_nav = [[
          <a href="/login" class="nav-link">Login</a>
          <a href="/register" class="nav-link">Register</a>
        ]]
      end
      
      template.currentRequests[co] = req

      local success, err = xpcall(function()
        handler(req, res, captures)
      end, debug.traceback)

      template.currentRequests[co] = nil

      if not success then
        print('[Server Error] Exception in handler: ', err)
        res:writeHead(500, { ['Content-Type'] = 'text/plain' })
        res:finish('500 Internal Server Error')
      end
    end)()
  else
    -- Fallback 404 Page
    res:writeHead(404, { ['Content-Type'] = 'text/html; charset=utf-8' })
    res:finish('<h1>404 Not Found</h1><p>The requested page does not exist on this server.</p>')
  end
end

-- 5. Start HTTP Server
local host = config.server.host
local port = config.server.port

-- Ensure data directories exist
local fs = require('fs')
fs.mkdir(config.paths.data, 511, function()
  fs.mkdir(config.paths.data .. "/avatars", 511, function()
    fs.mkdir(config.paths.data .. "/avatars/default", 511, function() end)
  end)
  fs.mkdir(config.paths.data .. "/replays", 511, function() end)
  fs.mkdir(config.paths.data .. "/beatmaps", 511, function() end)
  fs.mkdir(config.paths.data .. "/wallpaper", 511, function() end)
  fs.mkdir(config.paths.data .. "/welcome", 511, function() end)
  fs.mkdir("public/screenshots", 511, function() end)
end)

http.createServer(handleRequest):listen(port, host)
print(string.format('[AyanomiBancho] Server is online and listening at http://%s:%d', host, port))
