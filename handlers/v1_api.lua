-- handlers/v1_api.lua
-- JSON API handlers mirroring Ripple v1 API

local db = require('../db')
local json = require('json')
local url = require('url')

local v1 = {}

local function sendJson(res, data, code)
  local body = json.encode(data)
  res:writeHead(code or 200, {
    ['Content-Type'] = 'application/json; charset=utf-8',
    ['Content-Length'] = tostring(#body)
  })
  res:finish(body)
end

function v1.getUserScoresBest(req, res)
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  
  local userId = tonumber(params.id)
  local username = params.name
  local mode = tonumber(params.mode) or 0
  local isRelax = tonumber(params.relax) or 0
  local limit = math.min(tonumber(params.l) or 10, 100)
  
  if not userId and not username then
    return sendJson(res, { code = 400, message = "Missing user id or name" }, 400)
  end

  local userQuery = userId and "id = ?" or "username = ?"
  local userParam = userId or username
  
  local users = db.query("SELECT id FROM users WHERE " .. userQuery, userParam)
  local user = users[1]
  if not user then
    return sendJson(res, { code = 404, message = "User not found" }, 404)
  end

  local scores = db.query([[
    SELECT * FROM scores 
    WHERE userid = ? AND play_mode = ? AND is_relax = ? AND completed = 3
    ORDER BY pp DESC, score DESC 
    LIMIT ?
  ]], user.id, mode, isRelax, limit)

  sendJson(res, { code = 200, scores = scores })
end

function v1.getUserScoresRecent(req, res)
  local parsedUrl = url.parse(req.url, true)
  local params = parsedUrl.query or {}
  
  local userId = tonumber(params.id)
  local username = params.name
  local mode = tonumber(params.mode) or 0
  local isRelax = tonumber(params.relax) or 0
  local limit = math.min(tonumber(params.l) or 10, 100)
  
  if not userId and not username then
    return sendJson(res, { code = 400, message = "Missing user id or name" }, 400)
  end

  local userQuery = userId and "id = ?" or "username = ?"
  local userParam = userId or username
  
  local users = db.query("SELECT id FROM users WHERE " .. userQuery, userParam)
  local user = users[1]
  if not user then
    return sendJson(res, { code = 404, message = "User not found" }, 404)
  end

  local scores = db.query([[
    SELECT * FROM scores 
    WHERE userid = ? AND play_mode = ? AND is_relax = ?
    ORDER BY time DESC 
    LIMIT ?
  ]], user.id, mode, isRelax, limit)

  sendJson(res, { code = 200, scores = scores })
end

return v1
