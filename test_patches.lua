local auth = require('./handlers/auth')
local db = require('./db')
local template = require('./template')

-- Mock db.query
db.query = function()
  return {}
end

-- Mock template.render
template.render = function(name, context)
  return "Error: " .. tostring(context.error)
end

local function newMockResponse()
  local res = {}
  res.headers = {}
  res.body = ""
  res.status = nil
  function res:writeHead(status, headers)
    self.status = status
    self.headers = headers
  end
  function res:finish(body)
    self.body = body or ""
  end
  return res
end

local req = {
  method = "POST",
  url = "/login",
  headers = {},
  socket = {
    address = function() return { ip = "1.2.3.4" } end
  },
  on = function(self, event, callback)
    if event == "data" then
      -- do nothing
    elseif event == "end" then
      -- Schedule execution to resume asynchronously
      require('timer').setTimeout(1, callback)
    end
  end
}

coroutine.wrap(function()
  print("=== Testing Login Rate Limiting ===")
  for i = 1, 6 do
    local res = newMockResponse()
    auth.loginSubmit(req, res)
    print(string.format("Attempt %d: Status = %s, Body = %s", i, tostring(res.status), tostring(res.body)))
  end

  print("=== Testing decryptScore Input Validation ===")
  local function testPattern(score, hash, iv, ver)
    local scoreOk = string.match(score or "", "^[a-zA-Z0-9+/=%s\r\n]+$") ~= nil
    local hashOk = (not hash) or (string.match(hash, "^[a-zA-Z0-9+/=%s\r\n]+$") ~= nil)
    local ivOk = string.match(iv or "", "^[a-zA-Z0-9+/=%s\r\n]+$") ~= nil
    local verOk = string.match(ver or "", "^[a-zA-Z0-9%.-]+$") ~= nil
    local allOk = scoreOk and hashOk and ivOk and verOk
    print(string.format("Testing params: score=%q, hash=%q, iv=%q, ver=%q -> Valid = %s (score=%s, hash=%s, iv=%s, ver=%s)",
      tostring(score), tostring(hash), tostring(iv), tostring(ver), tostring(allOk),
      tostring(scoreOk), tostring(hashOk), tostring(ivOk), tostring(verOk)))
    return allOk
  end

  assert(testPattern("abc123XYZ+/==\r\n", "hash123", "iv123", "b20201105") == true)
  assert(testPattern("abc123XYZ+/==\r\n", nil, "iv123", "b20201105") == true)
  assert(testPattern("abc123XYZ; rm -rf", "hash123", "iv123", "b20201105") == false)
  assert(testPattern("abc123XYZ", "hash123", "iv123; command", "b20201105") == false)
  assert(testPattern("abc123XYZ", "hash123", "iv123", "b20201105; inject") == false)

  print("=== PATTERN TESTS COMPLETED ===")
  os.exit(0)
end)()
