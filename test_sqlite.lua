local sqlite3 = require('sqlite3')
local db = sqlite3.open("test_temp.db")

db:exec[[
  CREATE TABLE IF NOT EXISTS test (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    val TEXT
  );
]]

-- Clear test table
db:exec("DELETE FROM test;")

local function check(sql_str)
  local stmt = db:prepare(sql_str)
  local ncol = stmt:_ncol()
  print("Query:", sql_str)
  print("  _ncol():", ncol)
  stmt:close()
end

check("SELECT * FROM test;")
check("INSERT INTO test (val) VALUES ('hello');")
check("WITH cte AS (SELECT 1 AS x) SELECT * FROM cte;")
check("PRAGMA table_info(test);")

db:close()
os.remove("test_temp.db")
