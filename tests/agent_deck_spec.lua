---@module 'luassert'

local AgentDeck = require("sidekick.cli.session.agent_deck")

describe("agent-deck session backend", function()
  it("builds agent-deck commands", function()
    assert.are.same({ "agent-deck", "list", "--json" }, AgentDeck.cmd({ "list", "--json" }))
  end)

  it("builds current and title-less show commands", function()
    local original_json = AgentDeck.json
    local seen = {}
    AgentDeck.json = function(cmd)
      seen[#seen + 1] = cmd
      return { session = "claude deadbeef", id = "abc12345", status = "running" }
    end

    AgentDeck.current()
    AgentDeck.show()
    AgentDeck.json = original_json

    assert.are.same({ "agent-deck", "session", "current", "--json" }, seen[1])
    assert.are.same({ "agent-deck", "session", "show", "--json" }, seen[2])
  end)

  it("builds wrapper args for extra command flags", function()
    local cmd, wrapper = AgentDeck.tool_args({
      cmd = { "codex", "--dangerously-bypass-approvals-and-sandbox" },
      env = {},
    })

    assert.are.same("codex", cmd)
    assert.are.same("{command} '--dangerously-bypass-approvals-and-sandbox'", wrapper)
  end)

  it("builds wrapper args for env overrides", function()
    local cmd, wrapper = AgentDeck.tool_args({
      cmd = { "claude" },
      env = {
        BAR = false,
        FOO = "1",
      },
    })

    assert.are.same("claude", cmd)
    assert.are.same("env -u 'BAR' FOO='1' {command}", wrapper)
  end)

  it("filters active sessions from agent-deck list output", function()
    local original_json = AgentDeck.json
    AgentDeck.json = function()
      return {
        {
          id = "abc12345",
          title = "claude deadbeef1234",
          path = "/tmp/project",
          tool = "claude",
          status = "waiting",
          tmux_session = "agentdeck_claude_deadbeef",
        },
        {
          id = "def67890",
          title = "claude stopped",
          path = "/tmp/project",
          tool = "claude",
          status = "stopped",
        },
      }
    end

    local sessions = AgentDeck.sessions()
    AgentDeck.json = original_json

    assert.are.same({
      {
        id = "agent-deck: abc12345",
        cwd = "/tmp/project",
        tool = "claude",
        external = true,
        mux_backend = "agent-deck",
        mux_session = "agentdeck_claude_deadbeef",
        mux_session_display = "claude deadbeef1234",
        agent_deck_session_id = "abc12345",
        agent_deck_title = "claude deadbeef1234",
        pids = {},
      },
    }, sessions)
  end)

  it("reuses an existing started session as external", function()
    local original_list = AgentDeck.list
    local original_show = AgentDeck.show
    AgentDeck.list = function()
      return {
        {
          id = "abc12345",
          title = "claude deadbeef1234",
          path = "/tmp/project",
          tool = "claude",
          status = "running",
          tmux_session = "agentdeck_claude_deadbeef",
        },
      }
    end
    AgentDeck.show = function(ref)
      assert.are.same("abc12345", ref)
      return {
        id = "abc12345",
        title = "claude deadbeef1234",
        status = "running",
        tmux_session = "agentdeck_claude_deadbeef",
      }
    end

    local session = setmetatable({
      sid = "claude deadbeef1234",
      cwd = "/tmp/project",
      tool = { name = "claude", cmd = { "claude" } },
      started = false,
      external = false,
    }, { __index = AgentDeck })

    local ret = session:start()

    AgentDeck.list = original_list
    AgentDeck.show = original_show

    assert.is_nil(ret)
    assert.is_true(session.external)
    assert.is_true(session.started)
    assert.are.same("abc12345", session.agent_deck_session_id)
  end)

  it("keeps an attached session running via agent-deck identifiers", function()
    local original_list = AgentDeck.list
    AgentDeck.list = function()
      return {
        {
          id = "abc12345",
          title = "sidekick-nvim",
          path = "/tmp/project",
          tool = "claude",
          status = "running",
          tmux_session = "agentdeck_sidekick-nvim_c51191f0",
        },
      }
    end

    local session = setmetatable({
      sid = "claude deadbeef1234",
      cwd = "/tmp/project",
      tool = { name = "claude", cmd = { "claude" } },
      agent_deck_session_id = "abc12345",
      agent_deck_title = "sidekick-nvim",
      mux_session = "agentdeck_sidekick-nvim_c51191f0",
      started = false,
    }, { __index = AgentDeck })

    assert.is_true(session:is_running())
    assert.are.same("sidekick-nvim", session.agent_deck_title)

    AgentDeck.list = original_list
  end)
end)
