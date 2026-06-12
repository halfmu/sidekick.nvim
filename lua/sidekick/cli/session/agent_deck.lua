local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.AgentDeck: sidekick.cli.Session
---@field agent_deck_session_id? string
---@field agent_deck_title? string
local M = {}
M.__index = M
M.priority = 50
M.external = true

local ACTIVE = {
  idle = true,
  running = true,
  starting = true,
  waiting = true,
}

---@class sidekick.cli.session.agentdeck.Session
---@field id string
---@field title string
---@field path string
---@field group? string
---@field tool string
---@field command? string
---@field status string
---@field tmux_session? string
---@field session? string

---@param args string[]
---@return string[]
function M.cmd(args)
  local cmd = { "agent-deck" }
  vim.list_extend(cmd, args)
  return cmd
end

---@param cmd string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
---@return string?
local function exec_stdout(cmd, opts)
  local _, stdout = Util.exec(cmd, opts)
  return stdout
end

---@param cmd string[]
---@return any?
function M.json(cmd)
  local stdout = exec_stdout(cmd, { notify = false })
  if not stdout then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, stdout)
  return ok and decoded or nil
end

---@param value string
---@return string
local function shellescape(value)
  return vim.fn.shellescape(value)
end

---@param tool sidekick.cli.Tool
---@return string, string?
function M.tool_args(tool)
  local cmd = vim.deepcopy(tool.cmd)
  local base = table.remove(cmd, 1)
  local env_parts = {} ---@type string[]

  local env = tool.env or {}
  local env_keys = vim.tbl_keys(env)
  table.sort(env_keys)
  for _, key in ipairs(env_keys) do
    local value = env[key]
    if value == false then
      env_parts[#env_parts + 1] = "-u " .. shellescape(key)
    else
      env_parts[#env_parts + 1] = ("%s=%s"):format(key, shellescape(tostring(value)))
    end
  end

  local wrapper = {} ---@type string[]
  if #env_parts > 0 then
    wrapper[#wrapper + 1] = "env"
    vim.list_extend(wrapper, env_parts)
  end
  wrapper[#wrapper + 1] = "{command}"
  for _, arg in ipairs(cmd) do
    wrapper[#wrapper + 1] = shellescape(arg)
  end

  return base, #wrapper > 1 and table.concat(wrapper, " ") or nil
end

---@param session sidekick.cli.session.agentdeck.Session
function M:apply(session)
  self.agent_deck_session_id = session.id
  self.agent_deck_title = session.title or session.session
  self.id = "agent-deck: " .. session.id
  self.mux_session = session.tmux_session or session.title or session.session
  self.mux_session_display = session.title or session.session or self.mux_session
  self.started = ACTIVE[session.status] == true
end

---@return string
function M:ref()
  return self.agent_deck_session_id or self.agent_deck_title or self.sid
end

---@return sidekick.cli.terminal.Cmd
function M:terminal()
  return { cmd = M.cmd({ "session", "attach", self:ref() }) }
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  if not self.external then
    return self:terminal()
  end
end

---@param title? string
---@return sidekick.cli.session.agentdeck.Session?
function M.show(title)
  local cmd = M.cmd({ "session", "show", "--json" })
  if title and title ~= "" then
    table.insert(cmd, 3, title)
  end
  local data = M.json(cmd)
  return type(data) == "table" and data or nil
end

---@return sidekick.cli.session.agentdeck.Session?
function M.current()
  local data = M.json(M.cmd({ "session", "current", "--json" }))
  return type(data) == "table" and data or nil
end

---@return sidekick.cli.session.agentdeck.Session[]
function M.list()
  local data = M.json(M.cmd({ "list", "--json" }))
  return type(data) == "table" and data or {}
end

---@return sidekick.cli.session.agentdeck.Session?
function M:find()
  local current = vim.env.TMUX and M.current() or nil
  if current and (current.id == self.agent_deck_session_id or current.session == self.agent_deck_title or current.session == self.sid) then
    return M.show(current.id) or current
  end
  for _, session in ipairs(M.list()) do
    if
      session.id == self.agent_deck_session_id
      or session.title == self.agent_deck_title
      or session.tmux_session == self.mux_session
      or session.title == self.sid
      or (session.path == self.cwd and (session.tool == self.tool.name or session.command == self.tool.cmd[1]))
    then
      return session
    end
  end
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if Config.cli.mux.create ~= "terminal" then
    Util.warn({
      ("agent-deck does not support `opts.cli.mux.create = %q`."):format(Config.cli.mux.create),
      ("Falling back to `%q`."):format("terminal"),
      "Please update your config.",
    })
  end
  local session = self:find()
  if not session then
    local cmd_name, wrapper = M.tool_args(self.tool)
    local add = M.cmd({ "add", self.cwd, "-t", self.sid, "-c", cmd_name })
    if wrapper then
      vim.list_extend(add, { "--wrapper", wrapper })
    end
    if Util.exec(add, { notify = true }) == nil then
      return
    end
    session = M.show(self.sid)
  end
  if not session then
    Util.error(("Failed to create `%s` agent-deck session"):format(self.tool.name))
    return
  end
  self:apply(session)
  if self.started then
    self.external = true
    return
  end
  self.external = false
  if Util.exec(M.cmd({ "session", "start", self:ref() }), { notify = true }) == nil then
    return
  end
  session = M.show(self:ref()) or session
  self:apply(session)
  return self:terminal()
end

function M:is_running()
  local session = self:find()
  if not session then
    return false
  end
  self:apply(session)
  return self.started == true
end

function M:send(text)
  if text == "" then
    return
  end
  Util.exec(M.cmd({ "session", "send-keys", self:ref(), "--text", text }), { notify = true })
end

function M:submit()
  Util.exec(M.cmd({ "session", "send-keys", self:ref(), "--enter" }), { notify = true })
end

function M:dump()
  local _, stdout = Util.exec(M.cmd({ "session", "output", self:ref(), "--pane", "-q" }), { notify = false })
  return stdout
end

---@return sidekick.cli.session.State[]
function M.sessions()
  local ret = {} ---@type sidekick.cli.session.State[]
  local Terminal = require("sidekick.cli.terminal")

  local function find_pids(mux_session)
    local pids = {} ---@type integer[]
    for _, terminal in pairs(Terminal.terminals) do
      if terminal.mux_backend == "agent-deck" and terminal.mux_session == mux_session then
        vim.list_extend(pids, terminal.pids or {})
      end
    end
    return pids
  end

  for _, session in ipairs(M.list()) do
    if ACTIVE[session.status] then
      local mux_session = session.tmux_session or session.title
      ret[#ret + 1] = {
        id = "agent-deck: " .. session.id,
        cwd = session.path,
        tool = session.tool,
        external = true,
        mux_backend = "agent-deck",
        mux_session = mux_session,
        mux_session_display = session.title or session.session or mux_session,
        agent_deck_session_id = session.id,
        agent_deck_title = session.title,
        pids = find_pids(mux_session),
      }
    end
  end
  return ret
end

return M
