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

local NON_LOOP_OPS = {
  [OP_RIGHT] = true,
  [OP_LEFT] = true,
  [OP_INCR] = true,
  [OP_DECR] = true,
  [OP_PUTC] = true,
  [OP_GETC] = true,
}
local LOOP_OPS = {
  [OP_LOOP_BEGIN] = true,
  [OP_LOOP_END] = true,
}

function M.parse(lines)
  vim.validate {
    { lines, { "f", "s", "t" } },
  }

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
  local pending_token
  local line_nr = 1

  for line in line_iter do
    for col_nr = 1, #line do
      local op = line:byte(col_nr)

      if NON_LOOP_OPS[op] then
        if pending_token and pending_token.op == op then
          pending_token.count = pending_token.count + 1
        else
          tokens[#tokens + 1] = pending_token
          pending_token = { op = op, count = 1 }
        end
      elseif LOOP_OPS[op] then
        tokens[#tokens + 1] = pending_token
        pending_token = nil

        if op == OP_LOOP_BEGIN then
          tokens[#tokens + 1] = { op = op, end_token_i = nil }
          unresolved_loops[#unresolved_loops + 1] = {
            token_i = #tokens,
            line_nr = line_nr,
            col_nr = col_nr,
          }
        else -- op == OP_LOOPEND
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
            op = op,
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
  tokens[#tokens + 1] = pending_token
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
    local op = token.op

    if op == OP_RIGHT then
      memory_i = ((memory_i + token.count - 1) % #memory) + 1
    elseif op == OP_LEFT then
      memory_i = ((memory_i - token.count - 1) % #memory) + 1
    elseif op == OP_INCR then
      memory[memory_i] = (memory[memory_i] + token.count) % 256
    elseif op == OP_DECR then
      memory[memory_i] = (memory[memory_i] - token.count) % 256
    elseif op == OP_PUTC then
      api.nvim_out_write(string.char(memory[memory_i]):rep(token.count))
    elseif op == OP_GETC then
      for _ = 1, token.count do
        api.nvim_out_write "\n>\n"
        memory[memory_i] = fn.getchar() % 256
        api.nvim_out_write(string.char(memory[memory_i]))
      end
      api.nvim_out_write "\n"
    elseif op == OP_LOOP_BEGIN then
      if memory[memory_i] == 0 then
        token_i = token.end_token_i
      end
    elseif op == OP_LOOP_END then
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

function M.source(lines, opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    profile = false,
  })
  vim.validate {
    { opts.profile, "b" },
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

  step(function()
    M.interpret(tokens, opts.memory_size)
  end, "Execution (interpreted)")
end

return M
