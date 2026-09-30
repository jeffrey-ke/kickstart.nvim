-- Content anchors: find a line again by its text.
--
-- An anchor is the *text* of a line plus its nearest non-blank neighbours.
-- The primary way a mark follows its line across versions of a file is the
-- diff mapping in custom/versions.lua; this is the fallback for the one thing
-- a diff cannot say -- where a *deleted* line went -- and for stores written
-- before snapshots existed. A parked mark keeps its anchor and is resurrected
-- when the same text turns up again (the branch checked back out, the block
-- moved rather than removed).
--
-- Pure: every function takes a lines array, not a buffer, so the same code
-- anchors against `nvim_buf_get_lines` and against `vim.fn.readfile` (the
-- migration commands anchor files that are not open), and it can be tested
-- headless with a literal table.
--
-- Whitespace-insensitive throughout. A formatter that re-indents a block is
-- the most common way a line changes without changing, and the neighbours
-- that disambiguate a repeated line (`return nil`, `}`) are compared the same
-- way. The nearest *non-blank* neighbours rather than the adjacent lines,
-- because the adjacent line is so often blank -- an anchor of blanks would
-- match everywhere. Two per side: one is not enough to tell the `return nil`
-- that ends one function from the one that ends the next when the block
-- after it moved away.
local M = {}

-- How many non-blank neighbours to keep per side, and how many lines to
-- scan for them before giving up on that side.
local CONTEXT_LINES = 2
local CONTEXT_REACH = 8

-- A line this short (`}`, `end`, `)`) says nothing on its own: it needs a
-- neighbour to agree before it counts as found.
local TRIVIAL_LEN = 3

---@class Anchor
---@field text string   the line, whitespace removed
---@field above string[] nearest non-blank lines before it, nearest first, whitespace removed
---@field below string[] nearest non-blank lines after it, nearest first, whitespace removed

---@param s string
---@return string
local function norm(s)
  return (s:gsub('%s+', ''))
end

--- The nearest non-blank lines from `i` in direction `step`, normalized,
--- nearest first.
---@param lines string[]
---@param i integer
---@param step 1|-1
---@return string[]
local function ctx(lines, i, step)
  local out = {}
  for k = 1, CONTEXT_REACH do
    local s = lines[i + k * step]
    if s == nil then
      break
    end
    s = norm(s)
    if s ~= '' then
      out[#out + 1] = s
      if #out == CONTEXT_LINES then
        break
      end
    end
  end
  return out
end

--- The anchor for line `lnum` (1-based) of `lines`.
---@param lines string[]
---@param lnum integer
---@return Anchor
function M.capture(lines, lnum)
  return {
    text = norm(lines[lnum] or ''),
    above = ctx(lines, lnum, -1),
    below = ctx(lines, lnum, 1),
  }
end

--- How much of the stored context is still there? Membership, not position:
--- a neighbour that is still nearby counts even if a line was inserted
--- between. The nearest stored neighbour weighs 2, the next 1 -- the line
--- right beside the anchor is the one most likely to belong to it.
---@param stored string[]
---@param now string[]
---@return integer
local function agreement(stored, now)
  local score = 0
  for k, s in ipairs(stored or {}) do
    if vim.tbl_contains(now, s) then
      score = score + (CONTEXT_LINES - k + 1)
    end
  end
  return score
end

--- Where is `anchor` now? Every line whose text matches is a candidate; the
--- one whose neighbours agree most wins, nearest to `expect` on a tie.
--- Context dominates distance on purpose: a block that moved to the other
--- end of the file, neighbours intact, beats an identical line that happens
--- to sit near the old number.
---
--- Returns nil when nothing qualifies -- the caller decides what an orphan
--- becomes.
---@param lines string[]
---@param anchor Anchor
---@param expect integer  the line it was on, 1-based
---@param lo? integer     first line to consider (an end anchor searches from its start)
---@return integer|nil lnum
function M.resolve(lines, anchor, expect, lo)
  local best, best_key
  for i = math.max(lo or 1, 1), #lines do
    if norm(lines[i]) == anchor.text then
      local agree = agreement(anchor.above, ctx(lines, i, -1)) + agreement(anchor.below, ctx(lines, i, 1))
      if not (#anchor.text < TRIVIAL_LEN and agree == 0) then
        local key = agree * 1e9 - math.abs(i - expect)
        if not best_key or key > best_key then
          best, best_key = i, key
        end
      end
    end
  end
  return best
end

--- Re-anchor a span (`l1`..`l2`, 1-based) by its two ends. The end is looked
--- for at or after the new start, at the old span's length. When only the
--- start is found the span keeps its length, clamped to the file; when the
--- start is lost the span is an orphan.
---@param lines string[]
---@param start Anchor
---@param finish Anchor
---@param l1 integer
---@param l2 integer
---@return integer|nil l1, integer|nil l2, boolean exact  exact = both ends found
function M.resolve_span(lines, start, finish, l1, l2)
  local s = M.resolve(lines, start, l1)
  if not s then
    return nil, nil, false
  end
  local len = math.max(l2 - l1, 0)
  local e = M.resolve(lines, finish, s + len, s)
  if e then
    return s, e, true
  end
  return s, math.min(s + len, #lines), false
end

return M
