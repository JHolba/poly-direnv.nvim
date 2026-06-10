--- Shared test helpers for poly-direnv.nvim
---
--- Provides utilities for resetting module state between tests and
--- creating mock objects for vim.system.

local M = {}

--- Unload all poly-direnv modules from package.loaded so each test
--- gets fresh module instances with clean state.
function M.reset_modules()
  for name, _ in pairs(package.loaded) do
    if name:match("^poly%-direnv") then
      package.loaded[name] = nil
    end
  end
end

--- Create a mock for vim.system that captures calls and invokes
--- callbacks with controlled output.
---
--- Usage:
---   local mock = helpers.mock_vim_system()
---   mock.returns({ code = 0, stdout = '{"key": "value"}', stderr = "" })
---   -- ... call code that uses vim.system ...
---   assert.equals(mock.calls[1].cmd[1], "direnv")
---   mock.restore()
---
--- @return table mock object with .returns(), .calls, .restore()
function M.mock_vim_system()
  local original = vim.system
  local mock = {
    calls = {},
    _responses = {},
    _response_idx = 0,
  }

  --- Queue a response to be returned by the next vim.system call.
  --- Can be called multiple times to queue sequential responses.
  --- @param response table { code: integer, stdout: string?, stderr: string? }
  function mock.returns(response)
    table.insert(mock._responses, response)
  end

  --- Restore the original vim.system.
  function mock.restore()
    vim.system = original
  end

  vim.system = function(cmd, opts, on_exit)
    mock._response_idx = mock._response_idx + 1
    table.insert(mock.calls, { cmd = cmd, opts = opts })

    local response = mock._responses[mock._response_idx]
    if not response then
      error("mock_vim_system: no response queued for call #" .. mock._response_idx)
    end

    if on_exit then
      -- Invoke callback synchronously (tests don't need async)
      on_exit(response)
    end

    -- Return a handle with :wait() for synchronous callers
    return {
      wait = function()
        return response
      end,
    }
  end

  return mock
end

--- Sleep for a given number of milliseconds using vim.uv.
--- Useful for testing TTL expiration in cache tests.
--- @param ms integer milliseconds to sleep
function M.sleep_ms(ms)
  vim.uv.sleep(ms)
end

--- Process pending vim.schedule callbacks.
--- In headless nvim (-l), vim.schedule_wrap'd callbacks don't run until
--- the event loop is pumped. This helper flushes them synchronously by
--- scheduling a sentinel and waiting for it to execute.
function M.flush_schedule()
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  vim.wait(1000, function()
    return flushed
  end)
end

return M
