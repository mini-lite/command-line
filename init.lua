-- Change log-----------------------------------------------------------------

-- In progress: exectute even lite xl commands

-- TODO: organize messages to show
-- TODO: cancel is other event is captured like moving up down or switching window
-- TODO: history of commands controlled by up and down
-- TODO: add exceptions for items to show in status bar
-- TODO: check how to handle taking applying suggestions
-- TODO: clearing status bar shoul accept exceptions, like items we want to show next to it

-- DONE: all show messages uses show_message of command line
-- DONE: cursor shall stop blinking where arraws
-- DONE: move caret in command line
-- DONE: put characters in commad line at position of caret
-- DONE: command line steals cursor from editor turns off the cursor maybe width 0
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
local renderer = require("renderer")
local common = require "core.common"

local current_instance = nil
local current_message = nil
local temp_message = nil
local current_message_expiry = nil
local MESSAGE_DURATION = 1 -- seconds
local status_bar_item_name = "status:command_line"
local old_log = nil
local original_timeout = config.message_timeout
local original_caret_width = style.caret_width
local blink_period = 1.0

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
    caret_pos = 1,
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
  style.caret_width = common.round(0 * SCALE)
  self.caret_pos = 1
end

function CommandLine:get_last_user_input()
  return self.last_user_input
end

function CommandLine:execute_or_return_command()
  self.last_user_input = self.user_input
  self.user_input = ""
  self.in_command = false
  self.caret_width = original_caret_width
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
    self.caret_width = original_caret_width
    if self.cancel_callback then
      self.cancel_callback()
    end
  end
end

function CommandLine:get_message()
  local now = os.time()

  if temp_message and current_message_expiry and now <= current_message_expiry then
      return temp_message
  end

  if current_message then
      return current_message
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

local original_draw = core.status_view.draw
local item = core.status_view:get_item(status_bar_item_name)

local function render_caret(x, y)
  local t = (core.frame_start or 0) % blink_period
  if t > blink_period / 2 then return end -- blink off phase

  local h = style.font:get_height()
  renderer.draw_rect(x, y, 2, h, style.caret)
end


local original_draw = core.status_view.draw
core.status_view.draw = function(self)
  original_draw(self)

  if current_instance and current_instance.in_command then
    local prompt = current_instance.command_prompt_label
    local caret_pos = current_instance.caret_pos
    local input = current_instance.user_input -- only user input

    local prompt_width = style.font:get_width(prompt or "")
    local input_before_caret = (input or ""):sub(1, caret_pos - 1)
    local input_width = style.font:get_width(input_before_caret)

    local x = style.padding.x + prompt_width + input_width
    local y = self.position.y + style.padding.y

    core.root_view:defer_draw(function()
      render_caret(x, y)
    end)
  end
end

-- Intercept text input
local original_on_event = core.on_event
function core.on_event(type, ...)
  if current_instance and current_instance.in_command then
    local input = current_instance.user_input or ""
    current_instance.caret_pos = current_instance.caret_pos or #input + 1

    if type == "textinput" then
      local text = ...
      -- Insert text at caret_pos
      local before = input:sub(1, current_instance.caret_pos - 1)
      local after = input:sub(current_instance.caret_pos)
      current_instance.user_input = before .. text .. after
      current_instance.caret_pos = current_instance.caret_pos + #text
      return true
    elseif type == "keypressed" then
      blink_period = 0
      local key = ...
      if PLATFORM ~= "Linux" and ime.editing then return false end

      if key == "return" then
        current_instance:execute_or_return_command()
        return true
      elseif key == "escape" then
        current_instance:cancel_command()
        return true
      elseif key == "backspace" then
        if current_instance.caret_pos > 1 then
          local before = input:sub(1, current_instance.caret_pos - 2)
          local after = input:sub(current_instance.caret_pos)
          current_instance.user_input = before .. after
          current_instance.caret_pos = current_instance.caret_pos - 1
        end
        return true
      elseif key == "left" then
        if current_instance.caret_pos > 1 then
          current_instance.caret_pos = current_instance.caret_pos - 1
        end
        return true
      elseif key == "right" then
        if current_instance.caret_pos <= #current_instance.user_input then
          current_instance.caret_pos = current_instance.caret_pos + 1
        end
        return true
      elseif key == "up" then
        --if current_instance:history_up() then
        --  current_instance.caret_pos = #current_instance.user_input + 1
        --end
        return true
      elseif key == "down" then
        --if current_instance:history_down() then
        --  current_instance.caret_pos = #current_instance.user_input + 1
        --end
        return true
      end
    elseif type == "keyreleased" then
      blink_period = 1
    end
  end

  return original_on_event(type, ...)
end

-- optional: limit status view to command only
local ran = false
local api = {}
setmetatable(api, {
  __newindex = function(_, key, value)
    if key == "minimal_status_view" and value == true and not ran then
      ran = true
      core.add_thread(function()
        core.status_view:hide_items()
        core.status_view:show_items({ status_bar_item_name, "status:test" })
      end)
    end
    rawset(api, key, value)
  end
})

-- duration: 0 constant message
function api.show_message(content, timeout)
  clear_messages() -- flush messages
  if type(content) ~= "table" then return end
  if timeout and timeout > 0 then
    temp_message = content
    current_message_expiry = os.time() + timeout
  else
    current_message = content
  end
end

function api.set_item_name(name)
  status_bar_item_name = name
end

function api.add_status_item()
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
end

-- factory method
function api.new()
  return CommandLine:new()
end

return api

