-- Change log-----------------------------------------------------------------

-- In progress: exectute even lite xl commands

-- TODO: command line steals cursor from editor turns off the cursor maybe width 0
-- TODO: all show messages uses show_message of command line
-- TODO: history of commands controlled by up and down
-- TODO: cancel is other event is captured like moving up down or switching window
-- TODO: add exceptions for items to show in status bar
-- TODO: check how to handle taking applying suggestions
-- TODO: clearing status bar shoul accept exceptions

-- DONE: cursor is missing in command that is needed
-- DONE: command input receives SDL2 processed text input
-- DONE: processing keys still going to detect enter and esc and backspace
-- DONE: start working on autocompletion for the commands
-- DONE: console.log stealing the status bar (test it and see if still happen)
-- DONE: also / can use command-line ??
-- DONE: command-line must steal status-bar no matter what

------------------------------------------------------------------------------

-- mod-version:3
local core = require "core"
local keymap = require "core.keymap"
local ime = require "core.ime"
local system = require "system"
local style = require "core.style"
local command = require "core.command"
local config = require "core.config"
local StatusView = require "core.statusview"

local current_instance = nil
local current_message = nil
local current_message_expiry = nil
local MESSAGE_DURATION = 1 -- seconds
local status_bar_item_name = "status:command_line"
local old_log = nil
local original_timeout = config.message_timeout

-- helper to clear status bar messages
local function clear_messages()
  local sv = core.status_view
  if sv and sv.message then
    sv.message_timeout = 0 -- Expire it immediately
  end
end

---@class CommandLineInstance
local CommandLine = {}
CommandLine.__index = CommandLine

function CommandLine:new()
  local instance = setmetatable({
    in_command = false,
    user_input = "",
    last_user_input = "",
    command_prompt_label = "",
    done_callback = nil,
    cancel_callback = nil, 
    suggest_callback = function(_) return {} end
  }, self)
  current_instance = instance
  clear_messages() -- flush messages
  return instance
end

function CommandLine:set_prompt(prompt)
  self.command_prompt_label = prompt
end

function CommandLine:start_command(opts)
  old_log = core.log
  core.log = core.log_quiet
  self.in_command = true
  self.user_input = ""
  self.done_callback = opts and opts.submit or nil
  self.cancel_callback = opts and opts.cancel or nil 
  self.suggest_callback = opts and opts.suggest or function(_) return {} end
  current_instance = self
  clear_messages() -- flush messages
end

function CommandLine:get_last_user_input()
  return self.last_user_input
end

function CommandLine:execute_or_return_command()
  self.last_user_input = self.user_input
  self.user_input = ""
  self.in_command = false
  core.log = old_log

  if self.done_callback then
    self.done_callback(self.last_user_input)
    self.done_callback = nil
  end
end

function CommandLine:cancel_command()
  if self.in_command then
    self.user_input = ""
    self.in_command = false
    if self.cancel_callback then
      self.cancel_callback()
    end
  end
end

function CommandLine:get_message()
  local now = os.time()
  if current_message then
    if current_message_expiry == nil or now <= current_message_expiry then
      return current_message
    end
  end
  return {}
end

function CommandLine:get_status_string()
  if self.in_command then
    local suggestion_suffix = ""
    if #self.user_input > 0 then
      local suggestions = self.suggest_callback(self.user_input)
      local suggestion = suggestions and suggestions[1] and suggestions[1].text or ""
      if suggestion:sub(1, #self.user_input) == self.user_input and #suggestion > #self.user_input then
        suggestion_suffix = suggestion:sub(#self.user_input + 1)
      end
    end

    return {
      style.accent, self.command_prompt_label,
      style.text, self.user_input,
      style.dim, suggestion_suffix
    }
  else
      -- show message 
    return self.get_message()
  end
  return {}
end

core.status_view:add_item({
  name = status_bar_item_name,
  alignment = StatusView.Item.LEFT,
  get_item = function()
    return current_instance and current_instance:get_status_string() or {}
  end,
  position = 1000,
  tooltip = "command line",
  separator = core.status_view.separator2,
})

-- <experiment draw caret>
local renderer = require("renderer")
local original_draw = core.status_view.draw
local item = core.status_view:get_item(status_bar_item_name)

core.status_view.draw = function(self)
  original_draw(self)

  -- do it only when in command
  if current_instance and current_instance.in_command then
  local user_input_text = current_instance and current_instance.user_input.." " or ""
  local user_input_width = style.font:get_width(user_input_text)


  core.root_view:defer_draw(function()
    local x_base = 6 + style.font:get_width(current_instance.command_prompt_label or "")
    local content = item.get_item and item:get_item()
    local text = content and content.text or ""
    local w = style.font:get_width(text)
    local h = style.font:get_height()

    -- Assume item is left-aligned and near x = 0
    -- Or adjust for your layout if not
    local x = x_base + user_input_width + 3  -- base padding + text width + estetic pad
    local y = self.position.y + style.padding.y

    renderer.draw_rect(
      x,
      y,
      2,  -- thin caret
      h,
      {255, 0, 0, 255}
    )
  end)
  end
end
------------------------------------------------------------------------------

-- Intercept text input
local original_on_event = core.on_event
function core.on_event(type, ...)
  if current_instance and current_instance.in_command then
    if type == "textinput" then
      local text = ...
      current_instance.user_input = current_instance.user_input .. text
      return true

    elseif type == "keypressed" then
      local key = ...
      if PLATFORM ~= "Linux" and ime.editing then return false end

      if key == "return" then
        current_instance:execute_or_return_command()
        return true
      elseif key == "escape" then
        current_instance:cancel_command()
        return true
      elseif key == "backspace" then
        current_instance.user_input = current_instance.user_input:sub(1, -2)
        return true
      end
    end
  end

  return original_on_event(type, ...)
end

-- Optional: limit status view to command only
local ran = false
local api = {}
setmetatable(api, {
  __newindex = function(_, key, value)
    if key == "minimal_status_view" and value == true and not ran then
      ran = true
      core.add_thread(function()
        core.status_view:hide_items()
        core.status_view:show_items({status_bar_item_name, "status:test"})
      end)
    end
    rawset(api, key, value)
  end
})

-- duration: 0 constant message
function api.show_message(content, duration) 
  clear_messages() -- flush messages
  if type(content) ~= "table" then return end
  current_message = content
  local now = os.time()
  if duration == 0 then
    current_message_expiry = nil  -- permanent
  else
    current_message_expiry = now + (duration or MESSAGE_DURATION)
  end
end

-- factory method
function api.new()
  return CommandLine:new()
end

return api
