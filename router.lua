-- router.lua
-- Custom HTTP Router with Regex (Pattern) Matching and Static File Server for Luvit

local fs = require('fs')
local pathJoin = require('path').join

local Router = {}
Router.__index = Router

-- Common MIME types for static assets
local MIME_TYPES = {
  html = "text/html; charset=utf-8",
  css  = "text/css; charset=utf-8",
  js   = "application/javascript; charset=utf-8",
  png  = "image/png",
  jpg  = "image/jpeg",
  jpeg = "image/jpeg",
  gif  = "image/gif",
  ico  = "image/x-icon",
  svg  = "image/svg+xml",
  json = "application/json; charset=utf-8",
  txt  = "text/plain; charset=utf-8"
}

-- Asynchronous non-blocking file stat wrapper
local function statAsync(path)
  local co = coroutine.running()
  fs.stat(path, function(err, stat)
    coroutine.resume(co, err, stat)
  end)
  return coroutine.yield()
end

-- Asynchronous non-blocking file read wrapper
local function readFileAsync(path)
  local co = coroutine.running()
  fs.readFile(path, function(err, data)
    coroutine.resume(co, err, data)
  end)
  return coroutine.yield()
end

function Router.new(publicDir)
  local self = setmetatable({}, Router)
  self.routes = {}
  self.publicDir = publicDir or "./public"
  return self
end

-- Register a general route
function Router:add(method, pattern, handler)
  table.insert(self.routes, {
    method = method:upper(),
    pattern = pattern,
    handler = handler
  })
end

-- GET request route
function Router:get(pattern, handler)
  self:add('GET', pattern, handler)
end

-- POST request route
function Router:post(pattern, handler)
  self:add('POST', pattern, handler)
end

-- HEAD request route
function Router:head(pattern, handler)
  self:add('HEAD', pattern, handler)
end

-- Register route for any method
function Router:any(pattern, handler)
  self:add('GET', pattern, handler)
  self:add('POST', pattern, handler)
  self:add('HEAD', pattern, handler)
  self:add('PUT', pattern, handler)
  self:add('DELETE', pattern, handler)
end

-- Match incoming request against registered patterns
function Router:match(method, path)
  method = method:upper()
  for _, route in ipairs(self.routes) do
    if route.method == method or route.method == 'ANY' then
      -- Perform Lua pattern matching.
      -- If the pattern contains capturing groups, they are returned.
      -- We anchor the matching using ^ and $ if not already specified to prevent partial matches.
      local finalPattern = route.pattern
      if not string.find(finalPattern, "^%^") then
        finalPattern = "^" .. finalPattern
      end
      if not string.find(finalPattern, "%$$") then
        finalPattern = finalPattern .. "$"
      end
      
      local captures = { string.match(path, finalPattern) }
      if #captures > 0 then
        -- In Lua, if there are no capturing groups in the pattern but the pattern matches,
        -- string.match returns the entire matched string. We want to distinguish that.
        -- If #captures is 1 and it is equal to the original path, it means there were no captures.
        if #captures == 1 and captures[1] == path and not string.find(route.pattern, "%(") then
          captures = {}
        end
        return route.handler, captures
      end
    end
  end
  return nil
end

-- Serve static files in a non-blocking coroutine style
function Router:serveStatic(req, res, path)
  -- Prevent directory traversal attacks
  if string.find(path, "%.%.") then
    res:writeHead(403, { ['Content-Type'] = 'text/plain' })
    res:finish('403 Forbidden: Invalid Path')
    return true
  end

  -- Build full local file path
  local fileLoc = pathJoin(self.publicDir, path)
  
  -- Check file status
  local err, stat = statAsync(fileLoc)
  if err or not stat or stat.type ~= "file" then
    return false -- Not found in static directory, let routing continue or fallback to 404
  end

  -- Detect MIME type
  local ext = string.match(fileLoc, "%.([^%.]+)$")
  local mime = MIME_TYPES[ext or ""] or "application/octet-stream"

  -- Read file content asynchronously
  local readErr, content = readFileAsync(fileLoc)
  if readErr then
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
    return true
  end

  -- Serve file
  res:writeHead(200, {
    ['Content-Type'] = mime,
    ['Content-Length'] = tostring(#content),
    ['Cache-Control'] = 'public, max-age=3600'
  })
  res:finish(content)
  return true
end

return Router
