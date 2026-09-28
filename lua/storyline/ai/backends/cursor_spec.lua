local config = require("storyline.config")
local cursor = require("storyline.ai.backends.cursor")

describe("cursor.build_cmd", function()
  after_each(function()
    config.setup({})
  end)

  it("model 未設定なら --model を付けない", function()
    config.setup({
      backends = { cursor = { cmd = "cursor-agent", args = { "-p" } } },
    })
    assert.same({ "cursor-agent", "-p" }, cursor.build_cmd(config.options.backends.cursor))
  end)

  it("model があれば --model を付ける", function()
    config.setup({
      model = "cursor-grok-4.6-high",
      backends = { cursor = { cmd = "cursor-agent", args = { "-p" } } },
    })
    assert.same(
      { "cursor-agent", "-p", "--model", "cursor-grok-4.6-high" },
      cursor.build_cmd(config.options.backends.cursor)
    )
  end)
end)
