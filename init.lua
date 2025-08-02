-- mod-version:3
local core = require "core"
local keymap = require "core.keymap"
local StatusView = require "core.statusview"
local ime = require "core.ime"
local system = require "system"
local style = require "core.style"
local DocView = require "core.docview"
local command = require "core.command"

local M = {}

-- TODO: !, ~,  and similar are filtered should be fixed 
-- TODO: start working on autocompletion for the commands
-- TODO: console.log stealing the status bar (test it and see if still happen)

M.last_user_input = ""
M.command_prompt_label = ""
M.in_command = false
M.user_input = ""
M.done_callback = nil

function M.start_command(callback)
  M.in_command = true
  M.user_input = ""
  M.done_callback = callback or nil  -- optional
end

-- customize prompt
function M.set_prompt(prompt)
  M.command_prompt_label = string.format("%s:", prompt) 
end
    
-- start command
function M.start_command(callback)
  M.in_command = true
  M.user_input = ""
  M.done_callback = callback or nil  -- optional
end

-- get last user input
function M.get_last_user_input()
   return M.last_user_input 
end

-- execute_command
function M.execute_or_return_command()
  M.last_user_input = M.user_input
  M.user_input = ""
  M.in_command = false

  -- call if it was provided
  if M.done_callback then
    M.done_callback(M.last_user_input)
    M.done_callback = nil
  end
end

-- function to hold user input
function M.command_string()
  if M.in_command then
    return { M.command_prompt_label .. M.user_input }
  end
  return {}
end

-- Add status bar item once
-- TODO: find other position for command line or make it custom or clear all
if not core.status_view:get_item("status:command_line") then
  core.status_view:add_item({
    name = "status:command_line",
    alignment = StatusView.Item.LEFT,
    get_item = M.command_string,
    position = 1000, -- after other items
    tooltip = "command line input",
    separator = core.status_view.separator2
  })
end

local original_on_key_pressed = keymap.on_key_pressed

-- Accepts only A-Z and a-z
local function is_letter_key(k)
  return #k == 1 and k:match("%a")
end

function keymap.on_key_pressed(key, ...)
  if PLATFORM ~= "Linux" and ime.editing then
    return false
  end

  if M.in_command then
    if key == "return" then
      M.in_command = false
      M.execute_or_return_command()
    elseif key == "escape" then
      M.in_command = false
      M.user_input = ""
    elseif key == "backspace" then
      M.user_input = M.user_input:sub(1, -2)
    elseif key == "space" then
      M.user_input = M.user_input .. " "
    elseif is_letter_key(key) then
      M.user_input = M.user_input .. key
    end

    return true  -- prevents key from reaching the editor
  end

  return original_on_key_pressed(key, ...)
end

local ran = false

local mt = {
  __newindex = function(_, key, value)
    if key == "minimal_status_view" and value == true and not ran then
      ran = true
      core.add_thread(function()
        core.status_view:hide_items()
        core.status_view:show_items(
          "status:command_line"
        )
      end)
    end
    rawset(M, key, value)
  end
}

return setmetatable(M, mt)

