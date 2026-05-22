local db = require('./db')

local maps = db.query([[
  SELECT b.file_md5, b.parent_set_id, b.id, s.artist, s.title, b.diff_name
  FROM beatmaps b
  JOIN beatmapsets s ON b.parent_set_id = s.id
]])
print("Total maps in database:", #maps)
for i, m in ipairs(maps) do
  print(string.format("%d. ID: %s, MD5: %s, Set ID: %s, Artist: %s, Title: %s, Diff: %s", 
    i, m.id, m.file_md5, m.parent_set_id, m.artist, m.title, m.diff_name))
end

local sets = db.query("SELECT * FROM beatmapsets")
print("\nTotal beatmapsets in database:", #sets)
for i, s in ipairs(sets) do
  print(string.format("%d. Set ID: %s, Artist: %s, Title: %s, Creator: %s", 
    i, s.id, s.artist, s.title, s.creator))
end


