-- Zoom and pan inside the image buffers image.nvim hijacks: `+`/`-`/`0`, `hjkl`, Ctrl-scroll.
--
-- image.nvim can only draw an image fitted to a window -- the renderer clamps the rendered
-- width to the terminal width (image/renderer.lua:85) and derives the position from
-- screenpos(), so there is no offset to pan with. Zooming therefore happens on the source:
-- crop a region with ImageMagick and swap it under the existing Image object, which reloads
-- whenever `original_path` is newer than `last_modified` (image/image.lua:57). image.nvim
-- then scales that crop up to the size `apply` asks for, which is the zoom.

local ZOOM_STEP = 1.25
local MAX_ZOOM = 32
local PAN_STEP = 0.15 -- of the visible region, per keypress

local cache_dir = vim.fn.stdpath 'cache' .. '/image-zoom'

---@class ImageView
---@field source string  original file, before any cropping
---@field width number
---@field height number
---@field zoom number  1 = whole image, fitted
---@field cx number  center of the visible region, 0..1
---@field cy number
---@field seq number  crops are never overwritten; getftime() is whole seconds, so a
---                   reused path would look unchanged to image.nvim's reload check
---@field cropped boolean

---@type table<integer, ImageView>
local views = {}

local function clamp(value, lo, hi)
  return math.min(math.max(value, lo), hi)
end

local function current_image(buf)
  local images = require('image').get_images { window = vim.api.nvim_get_current_win(), buffer = buf }
  return images[1]
end

---@return ImageView?
local function view_for(buf, image)
  if views[buf] then return views[buf] end

  local result = vim.system({ 'identify', '-format', '%w %h', image.original_path .. '[0]' }, { text = true }):wait()
  local width, height = (result.stdout or ''):match '(%d+) (%d+)'
  if not width then
    vim.notify('image-zoom: cannot read the size of ' .. image.original_path, vim.log.levels.ERROR)
    return nil
  end

  views[buf] = {
    source = image.original_path,
    width = tonumber(width),
    height = tonumber(height),
    zoom = 1,
    cx = 0.5,
    cy = 0.5,
    seq = 0,
    cropped = false,
  }
  return views[buf]
end

---@param columns number  size to draw at, in cells
---@param rows number
local function show(image, path, columns, rows)
  image.original_path = path
  image.last_modified = -1
  image:render { width = math.max(1, columns), height = math.max(1, rows) }
end

local function apply(buf, view)
  local image = current_image(buf)
  if not image then return end
  local term = require('image/utils').term.get_size()
  if not term then return end

  if view.zoom <= 1 then view.zoom, view.cx, view.cy = 1, 0.5, 0.5 end

  -- Zoom scales the drawn image, and the window is a viewport onto it: the picture grows
  -- until it fills the window along an axis, and only past that is that axis cropped.
  -- Cropping to the source's aspect instead would keep a letterboxed image in its
  -- original box forever. Zoom 1 is what image.nvim draws unasked, native size shrunk to
  -- fit, so the first `+` continues from what is on screen.
  local win = vim.api.nvim_get_current_win()
  local win_width = vim.api.nvim_win_get_width(win) * term.cell_width
  local win_height = vim.api.nvim_win_get_height(win) * term.cell_height
  local scale = math.min(1, win_width / view.width, win_height / view.height) * view.zoom -- screen px per source px

  local crop_width = clamp(math.floor(win_width / scale), 16, view.width)
  local crop_height = clamp(math.floor(win_height / scale), 16, view.height)
  local columns = math.floor(crop_width * scale / term.cell_width)
  local rows = math.floor(crop_height * scale / term.cell_height)

  if crop_width == view.width and crop_height == view.height then
    view.cx, view.cy = 0.5, 0.5
    show(image, view.source, columns, rows)
    view.cropped = false
    return
  end

  local x = clamp(math.floor(view.cx * view.width - crop_width / 2 + 0.5), 0, view.width - crop_width)
  local y = clamp(math.floor(view.cy * view.height - crop_height / 2 + 0.5), 0, view.height - crop_height)
  -- fold the clamp back in, so panning into an edge doesn't bank offset to undo later
  view.cx = (x + crop_width / 2) / view.width
  view.cy = (y + crop_height / 2) / view.height

  view.seq = view.seq + 1
  local crop = ('%s/%d-%d.png'):format(cache_dir, buf, view.seq)
  local result = vim.system({
    'convert',
    view.source .. '[0]',
    '-crop',
    ('%dx%d+%d+%d'):format(crop_width, crop_height, x, y),
    '+repage',
    crop,
  }, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify('image-zoom: convert failed: ' .. (result.stderr or ''), vim.log.levels.ERROR)
    return
  end

  show(image, crop, columns, rows)
  view.cropped = true
end

local function attach(buf)
  vim.fn.mkdir(cache_dir, 'p')

  local map = function(lhs, adjust, desc)
    vim.keymap.set('n', lhs, function()
      local image = current_image(buf)
      if not image then return end
      local view = view_for(buf, image)
      if not view then return end
      adjust(view)
      apply(buf, view)
      vim.api.nvim_echo({ { ('%.2fx'):format(view.zoom), 'Comment' } }, false, {})
    end, { buffer = buf, desc = desc })
  end

  local zoom_by = function(factor)
    return function(view)
      view.zoom = clamp(view.zoom * factor, 1, MAX_ZOOM)
    end
  end
  local pan_by = function(dx, dy)
    return function(view)
      view.cx = clamp(view.cx + dx * PAN_STEP / view.zoom, 0, 1)
      view.cy = clamp(view.cy + dy * PAN_STEP / view.zoom, 0, 1)
    end
  end

  map('+', zoom_by(ZOOM_STEP), 'Zoom in')
  map('=', zoom_by(ZOOM_STEP), 'Zoom in')
  map('<C-ScrollWheelUp>', zoom_by(ZOOM_STEP), 'Zoom in')
  map('-', zoom_by(1 / ZOOM_STEP), 'Zoom out')
  map('<C-ScrollWheelDown>', zoom_by(1 / ZOOM_STEP), 'Zoom out')
  map('0', function(view)
    view.zoom = 1
  end, 'Reset zoom')

  map('h', pan_by(-1, 0), 'Pan left')
  map('l', pan_by(1, 0), 'Pan right')
  map('k', pan_by(0, -1), 'Pan up')
  map('j', pan_by(0, 1), 'Pan down')
  map('<Left>', pan_by(-1, 0), 'Pan left')
  map('<Right>', pan_by(1, 0), 'Pan right')
  map('<Up>', pan_by(0, -1), 'Pan up')
  map('<Down>', pan_by(0, 1), 'Pan down')
  map('<ScrollWheelUp>', pan_by(0, -1), 'Pan up')
  map('<ScrollWheelDown>', pan_by(0, 1), 'Pan down')
end

local function detach(buf)
  local view = views[buf]
  if not view then return end
  views[buf] = nil
  -- crops are handed to image.nvim's async transform queue, so they only go once the
  -- buffer is gone
  for seq = 1, view.seq do
    vim.fn.delete(('%s/%d-%d.png'):format(cache_dir, buf, seq))
  end
end

return {
  '3rd/image.nvim',
  build = false, -- so that it doesn't build the rock https://github.com/3rd/image.nvim/issues/91#issuecomment-2453430239
  opts = {
    processor = 'magick_cli',
    tmux_show_only_in_active_window = true,
    max_width_window_percentage = 100,
    max_height_window_percentage = 100,
  },
  config = function(_, opts)
    require('image').setup(opts)

    local group = vim.api.nvim_create_augroup('image-zoom', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'image_nvim',
      callback = function(event)
        attach(event.buf)
      end,
    })
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
      group = group,
      callback = function(event)
        detach(event.buf)
      end,
    })
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = group,
      callback = function()
        require('image').clear()
        vim.fn.delete(cache_dir, 'rf')
      end,
    })
  end,
}
