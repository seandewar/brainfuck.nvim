local api = vim.api
local fn = vim.fn
local uv = vim.loop

local M = {}

local OP_RIGHT = (">"):byte()
local OP_LEFT = ("<"):byte()
local OP_INCR = ("+"):byte()
local OP_DECR = ("-"):byte()
local OP_PUTC = ("."):byte()
local OP_GETC = (","):byte()
local OP_LOOP_BEGIN = ("["):byte()
local OP_LOOP_END = ("]"):byte()

local TOKEN_CURSOR_MOVE = 1
local TOKEN_CURSOR_WRITE = 2
local TOKEN_PUTC = 3
local TOKEN_GETC = 4
local TOKEN_LOOP_BEGIN = 5
local TOKEN_LOOP_END = 6

local MERGEABLE_OPS = {
  [OP_RIGHT] = { token_type = TOKEN_CURSOR_MOVE, count = 1 },
  [OP_LEFT] = { token_type = TOKEN_CURSOR_MOVE, count = -1 },
  [OP_INCR] = { token_type = TOKEN_CURSOR_WRITE, count = 1 },
  [OP_DECR] = { token_type = TOKEN_CURSOR_WRITE, count = -1 },
  [OP_PUTC] = { token_type = TOKEN_PUTC, count = 1 },
  [OP_GETC] = { token_type = TOKEN_GETC, count = 1 },
}

function M.parse(lines)
  vim.validate { { lines, { "f", "s", "t" } } }

  local line_iter
  if type(lines) == "function" then
    line_iter = lines
  elseif type(lines) == "string" then
    line_iter = vim.gsplit(lines, "\n", true)
  else -- type(lines) == "table"
    local i = 0
    line_iter = function()
      if i < #lines then
        i = i + 1
        return lines[i]
      end
    end
  end

  local tokens = {}
  local unresolved_loops = {}
  local pending_token = { type = TOKEN_CURSOR_MOVE, count = 0 }
  local line_nr = 1

  for line in line_iter do
    for col_nr = 1, #line do
      local op = line:byte(col_nr)
      local mergeable = MERGEABLE_OPS[op]

      if mergeable then
        if pending_token.type == mergeable.token_type then
          pending_token.count = pending_token.count + mergeable.count
        else
          if pending_token.count ~= 0 then
            tokens[#tokens + 1] = pending_token
          end
          pending_token = {
            type = mergeable.token_type,
            count = mergeable.count,
          }
        end
      elseif op == OP_LOOP_BEGIN or op == OP_LOOP_END then
        tokens[#tokens + 1] = pending_token
        pending_token = { type = TOKEN_CURSOR_MOVE, count = 0 }

        if op == OP_LOOP_BEGIN then
          tokens[#tokens + 1] = { type = TOKEN_LOOP_BEGIN, end_token_i = nil }
          unresolved_loops[#unresolved_loops + 1] = {
            token_i = #tokens,
            line_nr = line_nr,
            col_nr = col_nr,
          }
        else -- op == OP_LOOP_END
          if #unresolved_loops == 0 then
            error(
              ("parse error: unmatched ']' at line %d, col %d"):format(
                line_nr,
                col_nr
              )
            )
          end

          local begin_token_i = unresolved_loops[#unresolved_loops].token_i
          tokens[#tokens + 1] = {
            type = TOKEN_LOOP_END,
            begin_token_i = begin_token_i,
          }
          tokens[begin_token_i].end_token_i = #tokens
          unresolved_loops[#unresolved_loops] = nil
        end
      end
    end

    line_nr = line_nr + 1
  end

  if #unresolved_loops ~= 0 then
    local unresolved = unresolved_loops[#unresolved_loops]
    error(
      ("parse error: unmatched '[' at line %d, col %d"):format(
        unresolved.line_nr,
        unresolved.col_nr
      )
    )
  end
  if pending_token.count ~= 0 then
    tokens[#tokens + 1] = pending_token
  end
  return tokens
end

function M.interpret(tokens, memory_size, breakcheck_interval)
  memory_size = memory_size or 30000
  breakcheck_interval = breakcheck_interval or 500000
  vim.validate {
    { tokens, "t" },
    { memory_size, "n" },
    { breakcheck_interval, "n" },
  }

  local memory = {}
  for i = 1, memory_size do
    memory[i] = 0
  end

  local memory_i = 1
  local token_i = 1
  local breakcheck_counter = breakcheck_interval

  while token_i <= #tokens do
    local token = tokens[token_i]

    if token.type == TOKEN_CURSOR_MOVE then
      memory_i = ((memory_i + token.count - 1) % #memory) + 1
    elseif token.type == TOKEN_CURSOR_WRITE then
      memory[memory_i] = (memory[memory_i] + token.count) % 256
    elseif token.type == TOKEN_PUTC then
      api.nvim_out_write(string.char(memory[memory_i]):rep(token.count))
    elseif token.type == TOKEN_GETC then
      for _ = 1, token.count do
        api.nvim_out_write "\n>\n"
        memory[memory_i] = fn.getchar() % 256
        api.nvim_out_write(string.char(memory[memory_i]))
      end
      api.nvim_out_write "\n"
    elseif token.type == TOKEN_LOOP_BEGIN then
      if memory[memory_i] == 0 then
        token_i = token.end_token_i
      end
    elseif token.type == TOKEN_LOOP_END then
      if memory[memory_i] ~= 0 then
        token_i = token.begin_token_i
      end
    end

    token_i = token_i + 1
    breakcheck_counter = breakcheck_counter - 1
    if breakcheck_counter == 0 then
      fn.getchar(1) -- Peek so <C-c> has a chance to interrupt.
      breakcheck_counter = breakcheck_interval
    end
  end

  api.nvim_out_write "\n"
end

function M.transpile(tokens, memory_size)
  memory_size = memory_size or 30000
  vim.validate {
    { tokens, "t" },
    { memory_size, "n" },
  }

  local lines = {
    "local api = vim.api",
    "local fn = vim.fn",
    "local memory = {}",
    "for i = 1, " .. memory_size .. " do",
    "memory[i] = 0",
    "end",
    "local memory_i = 1",
  }

  for _, token in ipairs(tokens) do
    if token.type == TOKEN_CURSOR_MOVE then
      local offset = token.count - 1
      if offset ~= 0 then
        lines[#lines + 1] = ("memory_i = ((memory_i %s %d) %% %d) + 1"):format(
          offset > 0 and "+" or "-",
          math.abs(offset),
          memory_size
        )
      else
        lines[#lines + 1] = ("memory_i = (memory_i %% %d) + 1"):format(
          memory_size
        )
      end
    elseif token.type == TOKEN_CURSOR_WRITE then
      lines[#lines + 1] =
        (
          "memory[memory_i] = (memory[memory_i] %s %d) %% 256"
        ):format(token.count > 0 and "+" or "-", math.abs(token.count))
    elseif token.type == TOKEN_PUTC then
      if token.count == 1 then
        lines[#lines + 1] = "api.nvim_out_write(string.char(memory[memory_i]))"
      else
        lines[#lines + 1] = (
          "api.nvim_out_write(string.char(memory[memory_i]):rep("
          .. token.count
          .. "))"
        )
      end
    elseif token.type == TOKEN_GETC then
      for _ = 1, token.count do
        lines[#lines + 1] = [[api.nvim_out_write "\n>\n"]]
        lines[#lines + 1] = "memory[memory_i] = fn.getchar() % 256"
        lines[#lines + 1] = "api.nvim_out_write(string.char(memory[memory_i]))"
      end
      lines[#lines + 1] = [[api.nvim_out_write "\n"]]
    elseif token.type == TOKEN_LOOP_BEGIN then
      lines[#lines + 1] = "while memory[memory_i] ~= 0 do"
    elseif token.type == TOKEN_LOOP_END then
      lines[#lines + 1] = "end"
    end
  end

  lines[#lines + 1] = [[api.nvim_out_write "\n"]]
  return lines
end

function M.source(lines, opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    profile = false,
    compile = false,
  })
  vim.validate {
    { opts.profile, "b" },
    { opts.compile, "b" },
  }

  local step
  if opts.profile then
    step = function(f, action)
      local start_time = uv.hrtime()
      local result = f()
      local end_time = uv.hrtime()
      api.nvim_echo({
        {
          ("%s took %fs"):format(action, (end_time - start_time) / 1000000000),
          "Debug",
        },
      }, true, {})
      return result
    end
  else
    step = function(f)
      return f()
    end
  end

  local tokens = step(function()
    return M.parse(lines)
  end, "Parsing")

  if opts.compile then
    local string = table.concat(
      step(function()
        return M.transpile(tokens, opts.memory_size)
      end, "Transpile to Lua"),
      "\n"
    )

    local info = step(function()
      local program, err = loadstring(string, "transpiled brainfuck program")
      return { program = program, err = err }
    end, "Lua loadstring()")
    if not info.program then
      error(
        "Lua loadstring() of transpiled program failed!"
          .. " This is a brainfuck.nvim bug. Details: "
          .. info.err
      )
    end

    step(info.program, "Execution (compiled)")
  else
    step(function()
      M.interpret(tokens, opts.memory_size)
    end, "Execution (interpreted)")
  end
end

return M
