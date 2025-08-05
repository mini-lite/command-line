-- Change log-----------------------------------------------------------------

-- DONE: command input receives SDL2 processed text input
-- DONE: processing keys still going to detect enter and esc and backspace
-- DONE: start working on autocompletion for the commands
-- DONE: console.log stealing the status bar (test it and see if still happen)
-- DONE: also / can use command-line ??
-- DONE: command-line must steal status-bar no matter what
-- In progress: exectute even lite xl commands

-- TODO: cursor is missing in command that is needed
-- TODO: history of commands controlled by up and down
-- TODO: cancel is other event is captured like moving up down or switching window
-- TODO: add exceptions for items to show in status bar
-- TODO: check how to handle taking applying suggestions
-- TODO: clearing status bar shoul accept exceptions

------------------------------------------------------------------------------

-- mod-version:3
local core = require "core"
local keymap = require "core.keymap"
local StatusView = require "core.statusview"
local ime = require "core.ime"
local system = require "system"
local style = require "core.style"
local command = require "core.command"
local config = require "core.config"

local current_instance = nil
local status_bar_item_name = "status:command_line"
local old_log = nil
local original_timeout = config.message_timeout

---@class CommandLineInstance
local CommandLine = {}
CommandLine.__index = CommandLine

function CommandLine:new()
  return setmetatable({
    in_command = false,
    user_input = "",
    last_user_input = "",
    command_prompt_label = "",
    done_callback = nil,
    cancel_callback = nil, 
    suggest_callback = function(_) return {} end
  }, self)
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

  -- force-clear current message only, without changing global timeout logic
  local sv = core.status_view
  if sv and sv.message then
    sv.message_timeout = 0  -- Expire it immediately
  end
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
  end
  return {}
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

-- static status item (shared across all instances)
if not core.status_view:get_item(status_bar_item_name) then
  core.status_view:add_item({
    name = status_bar_item_name,
    alignment = StatusView.Item.LEFT,
    get_item = function()
      return current_instance and current_instance:get_status_string() or {}
    end,
    position = 1000,
    tooltip = "command input",
    separator = core.status_view.separator2
  })
end

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
        core.status_view:show_items({status_bar_item_name, "status:vim_mode"})
      end)
    end
    rawset(api, key, value)
  end
})

-- console log taiming

-- factory method
function api.new()
  return CommandLine:new()
end

return api
