local utf8 = require('.utf8'):init()

local h_wall = '─'
local v_wall = '│'
local junction = '┼'
local top_left = '┌'
local top_right = '┐'
local bottom_left = '└'
local bottom_right = '┘'

local function box_top(chars)
  chars = utf8.sub(chars, 2, -2)
  chars = utf8.gsub(chars, '-', h_wall)
  chars = utf8.gsub(chars, '+', junction)
  return top_left .. chars .. top_right
end

local function box_bottom(chars)
  chars = utf8.sub(chars, 2, -2)
  chars = utf8.gsub(chars, '-', h_wall)
  chars = utf8.gsub(chars, '+', junction)
  return bottom_left .. chars .. bottom_right
end

-- String buffers represent a single line of text split into one or more
-- segments. This allows for efficiently modifying strings in place. To
-- retrieve the final string, call `StringBuf.to_string`.
local StringBuf = {}

function StringBuf.new(str)
  return { str }
end

function StringBuf.sub(buf, i, j)
  local segments = {}
  for _, segment in ipairs(buf) do
    local len = utf8.len(segment)
    local stop = j
    if j > len then
      stop = len
    end

    if i > len then
      i = i - len
      goto next_iteration
    end

    -- use as much of this segment as we can
    table.insert(segments, utf8.sub(segment, i, stop))
    i = 1 -- start at the beginning of subsequent segments

    -- if this was the final segment, we're done
    if j <= len then
      break
    end

    ::next_iteration::
    j = j - len
  end
  return table.concat(segments, '')
end

function StringBuf.char_at(buf, index)
  for _, segment in ipairs(buf) do
    local len = utf8.len(segment)
    if index <= len then
      return utf8.sub(segment, index, index)
    end

    index = index - len
  end
end

function StringBuf.replace_range(buf, start_col, end_col, str)
  -- look for the segment that contains start_col and compact any subsequent
  -- segments until start_col and end_col are in the same segment
  local compact_start = nil
  local compact_stop = nil
  local i = start_col
  local j = end_col
  for segment_index, segment in ipairs(buf) do
    local len = utf8.len(segment)

    -- skip the segment and shift the compact frame if we haven't reached start_col yet
    if compact_start == nil then
      if i > len then
        i = i - len
        goto next_iteration
      else
        compact_start = segment_index
      end
    end

    -- if we've reached end_col, stop advancing the compact frame
    if j <= len then
      compact_stop = segment_index
      break
    end

    ::next_iteration::
    j = j - len
  end

  if compact_stop > compact_start then
    for _ = compact_start, compact_stop - 1 do
      buf[compact_start] = buf[compact_start] .. table.remove(buf, compact_start + 1)
    end
  end

  for segment_index, segment in ipairs(buf) do
    local len = utf8.len(segment)

    -- [start_col, end_col] are guaranteed to be in a single segment since we just compacted them
    if end_col <= len then
      -- split the existing segment along the given range
      -- for example, replacing the `xxx` range with `RRR` results in:
      --
      --     {aaaxxxbbb}
      --     {aaa} {RRR} {bbb}
      --

      -- remove existing segment
      table.remove(buf, segment_index)

      -- note that the following steps are performed in reverse order
      -- (trailing, inner, leading) since they're all inserted at the
      -- same index (each insert will shift the previous to the right)

      -- trailing characters (if any)
      if end_col < len then
        table.insert(buf, segment_index, utf8.sub(segment, end_col + 1))
      end

      -- replaced range
      table.insert(buf, segment_index, str)

      -- leading characters (if any)
      if start_col > 1 then
        table.insert(buf, segment_index, utf8.sub(segment, 1, start_col - 1))
      end

      break
    end

    start_col = start_col - len
    end_col = end_col - len
  end
end

function StringBuf.replace(buf, col, char)
  StringBuf.replace_range(buf, col, col, char)
end

function StringBuf.debug(buf)
  io.write('StringBuf{ ')
  for _, segment in ipairs(buf) do
    io.write('{' .. segment .. '} ')
  end
  io.write('}\n')
end

function StringBuf.to_string(buf)
  return table.concat(buf)
end

-- A line buffer allows for (somewhat) efficiently editing a set of lines
-- in-place; internally, it represents a string as an array of lines, where
-- each line is itself an array of string segments. A line may be modified
-- by replacing a range of characters, which will split the existing segment
-- into characters before/after the range.
--
-- The following line buffer results from the input string 'foo bar\nbaz':
--
--     {
--       { 'foo bar' },
--       { 'bar' },
--     }
--
-- Replacing column 4 on line 1 with '-' results in this change:
--
--     {
--       { 'foo', '-', 'bar' },
--       { 'bar' }
--     }
--
-- You can retrieve the modified string by calling `line_buffer.to_string`.
local LineBuffer = {}

function LineBuffer.new(str)
  local buf = {}
  for line in string.gmatch(str, '([^\n]*)\n?') do
    table.insert(buf, StringBuf.new(line))
  end
  return buf
end

function LineBuffer.from_lines(lines)
  local buf = {}
  for _, line in ipairs(lines) do
    table.insert(buf, StringBuf.new(line))
  end
  return buf
end

function LineBuffer.replace_range(buf, row, start_col, end_col, str)
  StringBuf.replace_range(buf[row], start_col, end_col, str)
end

function LineBuffer.replace(buf, row, col, char)
  LineBuffer.replace_range(buf, row, col, col, char)
end

function LineBuffer.sub(buf, row, start_col, end_col)
  return StringBuf.sub(buf[row], start_col, end_col)
end

function LineBuffer.char_at(buf, row, col)
  if buf[row] == nil then
    return nil
  end

  return StringBuf.char_at(buf[row], col)
end

function LineBuffer.to_string(buf)
  local lines = {}
  for _, segments in ipairs(buf) do
    table.insert(lines, StringBuf.to_string(segments))
  end
  return table.concat(lines, '\n')
end

function LineBuffer.to_lines(buf)
  local lines = {}
  for _, segments in ipairs(buf) do
    table.insert(lines, StringBuf.to_string(segments))
  end
  return lines
end

local function wall_char(buf, row, col)
  if LineBuffer.char_at(buf, row, col) == '|' then
    return v_wall
  else
    return junction
  end
end

local function format_block(buf, row, start_col, end_col)
  -- look ahead and make sure there's at least a top/bottom on separate rows
  -- (we want to exclude standalone `+-----+` sequences that aren't part of a box)
  local next_row_char = LineBuffer.char_at(buf, row + 1, start_col)
  if next_row_char ~= '|' and next_row_char ~= '+' then
    return
  end

  -- draw box top
  local top = LineBuffer.sub(buf, row, start_col, end_col)
  LineBuffer.replace_range(buf, row, start_col, end_col, box_top(top))

  -- draw sides
  row = row + 1
  local char = LineBuffer.char_at(buf, row, start_col)
  local inside_box = char == '|' or (char == '+' and LineBuffer.char_at(buf, row + 1, start_col) == '|')
  while inside_box do
    LineBuffer.replace(buf, row, start_col, wall_char(buf, row, start_col))
    LineBuffer.replace(buf, row, end_col, wall_char(buf, row, end_col))

    row = row + 1
    char = LineBuffer.char_at(buf, row, start_col)
    inside_box = char == '|' or (char == '+' and LineBuffer.char_at(buf, row + 1, start_col) == '|')
  end

  -- draw box bottom
  local bottom = LineBuffer.sub(buf, row, start_col, end_col)
  LineBuffer.replace_range(buf, row, start_col, end_col, box_bottom(bottom))
end

local M = {}

local function blockify(buf)
  for row = 1, #buf do
    local offset = 0
    local line = StringBuf.to_string(buf[row])
    local match_start, match_end = utf8.find(line, '%+[%-%+┼]+%+')
    -- look for box tops (a plus on either end and at least 3 dashes in the middle)
    while match_start ~= nil do
      if match_end - match_start + 1 >= 5 then
        format_block(buf, row, offset + match_start, offset + match_end)
      end

      offset = offset + match_end
      line = utf8.sub(line, match_end + 1)
      match_start, match_end = utf8.find(line, '%+[%-%+┼]+%+')
    end
  end
end

function M.blockify_str(str)
  local buf = LineBuffer.new(str)
  blockify(buf)
  return LineBuffer.to_string(buf)
end

-- TODO: add support for visual selection
-- ref: https://www.reddit.com/r/neovim/comments/j7wub2/comment/g89awan/
function M.blockify_current_buf()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
  local buf = LineBuffer.from_lines(lines)
  blockify(buf)
  vim.api.nvim_buf_set_lines(0, 0, -1, true, LineBuffer.to_lines(buf))
end

local test_input = [[

  +---------+    +---+
  |         |    |   | <- smallest
  |  some   |    +---+
  |   text  |
  |         | <- standard
  +---------+

        +--------------+
        |              |
  +-----+----+         |
  |     |    |         |
  |     +----+---------+
  |          | <- overlapping
  +----------+

  this ++ shouldn't +-+ be +--+ modified

  +---+ <- this should probably work
  +---+

  +---+ <- this shouldn't do anything

]]

-- print(M.blockify_str(test_input))

return M
