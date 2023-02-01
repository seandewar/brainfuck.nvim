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

local MERGEABLE_OP_TOKEN = {
  [OP_RIGHT] = { type = TOKEN_CURSOR_MOVE, count = 1 },
  [OP_LEFT] = { type = TOKEN_CURSOR_MOVE, count = -1 },
  [OP_INCR] = { type = TOKEN_CURSOR_WRITE, count = 1 },
  [OP_DECR] = { type = TOKEN_CURSOR_WRITE, count = -1 },
  [OP_PUTC] = { type = TOKEN_PUTC, count = 1 },
  [OP_GETC] = { type = TOKEN_GETC, count = 1 },
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
  local contained_loops = {}
  local unresolved_loops = {}
  local pending_token = { type = TOKEN_CURSOR_MOVE, count = 0 }
  local line_nr = 1

  for line in line_iter do
    for col_nr = 1, #line do
      local op = line:byte(col_nr)
      local mergeable_token = MERGEABLE_OP_TOKEN[op]

      if mergeable_token then
        if pending_token.type == mergeable_token.type then
          pending_token.count = pending_token.count + mergeable_token.count
        else
          if pending_token.count ~= 0 then
            tokens[#tokens + 1] = pending_token
          end
          pending_token = {
            type = mergeable_token.type,
            count = mergeable_token.count,
          }
        end
      elseif op == OP_LOOP_BEGIN or op == OP_LOOP_END then
        tokens[#tokens + 1] = pending_token
        pending_token = { type = TOKEN_CURSOR_MOVE, count = 0 }

        if op == OP_LOOP_BEGIN then
          tokens[#tokens + 1] = { type = TOKEN_LOOP_BEGIN, end_token_i = nil }
          local parent_loop = unresolved_loops[#unresolved_loops]
          if parent_loop then
            local contained = contained_loops[parent_loop.token_i]
            contained[#contained + 1] = #tokens
          end
          unresolved_loops[#unresolved_loops + 1] = {
            token_i = #tokens,
            line_nr = line_nr,
            col_nr = col_nr,
          }
          contained_loops[#tokens] = {}
        else -- op == OP_LOOP_END
          if #unresolved_loops == 0 then
            error(
              ("Parse error: unmatched ']' at line %d, col %d"):format(
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
      ("Parse error: unmatched '[' at line %d, col %d"):format(
        unresolved.line_nr,
        unresolved.col_nr
      )
    )
  end
  if pending_token.count ~= 0 then
    tokens[#tokens + 1] = pending_token
  end
  return tokens, contained_loops
end

local NL = ("\n"):byte()

function M.interpret(tokens, opts)
  vim.validate {
    { tokens, "t" },
    { opts, "t", true },
  }
  opts = vim.tbl_extend("keep", opts or {}, {
    memory_size = 3000,
    breakcheck_interval = 500000,
    terminal = true,
  })
  vim.validate {
    { opts.memory_size, "n" },
    { opts.breakcheck_interval, "n" },
    { opts.terminal, "b" },
  }

  local memory = {}
  for i = 1, opts.memory_size do
    memory[i] = 0
  end

  local memory_i = 1
  local token_i = 1
  local breakcheck_counter = opts.breakcheck_interval

  -- Returns true if we're not at the end of the tokens tape.
  local function interpret_until_breakcheck(putc, getc)
    while token_i <= #tokens do
      local token = tokens[token_i]

      if token.type == TOKEN_CURSOR_MOVE then
        memory_i = ((memory_i + token.count - 1) % #memory) + 1
      elseif token.type == TOKEN_CURSOR_WRITE then
        memory[memory_i] = (memory[memory_i] + token.count) % 256
      elseif token.type == TOKEN_PUTC then
        putc(memory[memory_i], token.count)
      elseif token.type == TOKEN_GETC then
        local char = getc(token.count)
        if not char then
          return true
        end
        memory[memory_i] = char
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
        breakcheck_counter = opts.breakcheck_interval
        return true
      end
    end

    return false
  end

  local function run_terminal()
    local buf = api.nvim_create_buf(true, true)
    if buf == 0 then
      error "Failed to create terminal buffer"
    end

    local screen_width = vim.o.columns
    local screen_height = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
    local width = math.max(1, screen_width - 5)
    local height = math.max(1, screen_height - 5)

    local win = api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = (screen_width - width) / 2,
      row = (screen_height - height) / 2,
      style = "minimal",
      border = "rounded",
      title = " Brainfuck (Interpreted) ",
      title_pos = "center",
    })
    if win == 0 then
      api.nvim_buf_delete(buf, { force = true })
      error "Failed to create terminal window"
    end

    api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

    local continue
    local input_buf_needed
    local input_buf = ""

    local chan = api.nvim_open_term(buf, {
      on_input = function(_, _, _, data)
        input_buf = input_buf .. data

        if input_buf_needed ~= nil and #input_buf >= input_buf_needed then
          input_buf_needed = nil
          vim.schedule(continue)
        end
      end,
    })
    if chan == 0 then
      api.nvim_win_close(win, true)
      error "Failed to create terminal instance"
    end

    api.nvim_echo(
      { { [[Press i to send input, CTRL-\ CTRL-N to stop.]] } },
      false,
      {}
    )

    local function putc(char, count)
      local chars = string.char(char):rep(count)
      -- Need to send a CR to start at the beginning of the new line.
      api.nvim_chan_send(chan, char == NL and ("\r" .. chars) or chars)
    end

    local function getc(count)
      if #input_buf < count then
        input_buf_needed = count
        return nil
      end

      -- TODO: maybe turn input_buf into a circular buffer instead...
      local echoed = input_buf:sub(1, count):gsub("\r", "\r\n")
      local char = input_buf:byte(count)
      api.nvim_chan_send(chan, echoed)
      input_buf = input_buf:sub(count + 1)
      return char
    end

    continue = function()
      if not api.nvim_buf_is_loaded(buf) then
        return
      end

      if interpret_until_breakcheck(putc, getc) then
        if input_buf_needed == nil then
          vim.schedule(continue)
        end
      else
        fn.chanclose(chan)
      end
      vim.cmd.redraw() -- nvim_chan_send() might not cause a terminal redraw.
    end

    continue()
  end

  local function run_cmdline()
    local function putc(char, count)
      api.nvim_out_write(string.char(char):rep(count))
    end

    local function getc(count)
      local char
      for _ = 1, count do
        api.nvim_out_write "\n>\n"
        char = fn.getchar() % 256
        api.nvim_out_write(string.char(char))
      end
      api.nvim_out_write "\n"
      return char
    end

    while interpret_until_breakcheck(putc, getc) do
      fn.getchar(1) -- Peek so <C-c> has a chance to interrupt.
    end
    api.nvim_out_write "\n" -- May still have an incomplete line buffered.
  end

  if opts.terminal then
    run_terminal()
  else
    run_cmdline()
  end
end

function M.transpile(tokens, contained_loops, memory_size, breakcheck_interval)
  memory_size = memory_size or 30000
  breakcheck_interval = breakcheck_interval or 500000
  vim.validate {
    { tokens, "t" },
    { contained_loops, "t" },
    { memory_size, "n" },
    { breakcheck_interval, "n" },
  }

  -- The Lua VM is limited by how far it can jump in a loop; if this limit is
  -- exceeded, you get a "control structure too long" error. Mitigate this.
  -- Also, calculate the total inner weight of this loop, excluding the contents
  -- of nested loops (used for break-checking).
  local loop_weights = {}
  local function calc_loop_weights(token_i)
    if loop_weights[token_i] then
      return
    end

    local weights = {
      inner_non_loop = tokens[token_i].end_token_i - token_i,
      outlined = 0,
      should_outline = false,
    }
    for _, inner_token_i in ipairs(contained_loops[token_i]) do
      calc_loop_weights(inner_token_i)
      local inner_weights = loop_weights[inner_token_i]
      weights.inner_non_loop = weights.inner_non_loop
        - (tokens[inner_token_i].end_token_i - inner_token_i)
      weights.outlined = weights.outlined + inner_weights.outlined
    end

    local inline_weight = tokens[token_i].end_token_i
      - token_i
      - weights.outlined
    if inline_weight > 1000 then
      weights.outlined = weights.outlined + inline_weight - 10
      weights.should_outline = true
    end
    loop_weights[token_i] = weights
  end
  for token_i, _ in pairs(contained_loops) do
    calc_loop_weights(token_i)
  end

  local lines = {
    "local a = vim.api",
    "local m = {}",
    "for i = 1, " .. memory_size .. " do",
    "m[i] = 0",
    "end",
    "local i = 1",
  }

  if breakcheck_interval > 0 then
    vim.list_extend(lines, {
      "local c = " .. breakcheck_interval,
      "local function b(e)",
      "c = c - e",
      "if c > 0 then",
      "return",
      "end",
      'a.nvim_call_function("getchar", {1})',
      "c = (c - 1) % " .. breakcheck_interval .. " + 1",
      "end",
    })
  end

  for token_i, token in ipairs(tokens) do
    if token.type == TOKEN_CURSOR_MOVE then
      local offset = token.count - 1
      if offset ~= 0 then
        lines[#lines + 1] = ("i = (i %s %d) %% %d + 1"):format(
          offset > 0 and "+" or "-",
          math.abs(offset),
          memory_size
        )
      else
        lines[#lines + 1] = ("i = i %% %d + 1"):format(memory_size)
      end
    elseif token.type == TOKEN_CURSOR_WRITE then
      lines[#lines + 1] = ("m[i] = (m[i] %s %d) %% 256"):format(
        token.count > 0 and "+" or "-",
        math.abs(token.count)
      )
    elseif token.type == TOKEN_PUTC then
      if token.count == 1 then
        lines[#lines + 1] = "a.nvim_out_write(string.char(m[i]))"
      else
        lines[#lines + 1] =
          ("a.nvim_out_write(string.char(m[i]):rep(%d))"):format(
            token.count
          )
      end
    elseif token.type == TOKEN_GETC then
      for _ = 1, token.count - 1 do
        lines[#lines + 1] = [[a.nvim_out_write "\n>\n"]]
        lines[#lines + 1] =
          'a.nvim_out_write(string.char(a.nvim_call_function("getchar", {}) % 256))'
      end
      lines[#lines + 1] = [[a.nvim_out_write "\n>\n"]]
      lines[#lines + 1] = 'm[i] = a.nvim_call_function("getchar", {}) % 256'
      lines[#lines + 1] = "a.nvim_out_write(string.char(m[i]))"
      lines[#lines + 1] = [[a.nvim_out_write "\n"]]
    elseif token.type == TOKEN_LOOP_BEGIN then
      if loop_weights[token_i].should_outline then
        lines[#lines + 1] = "local function f" .. token_i .. "()"
      else
        lines[#lines + 1] = "while m[i] ~= 0 do"
      end
    elseif token.type == TOKEN_LOOP_END then
      if breakcheck_interval > 0 then
        -- Break-checking on possible backward braches is good enough.
        lines[#lines + 1] = "b("
          .. loop_weights[tokens[token_i].begin_token_i].inner_non_loop
          .. ")"
      end
      if loop_weights[token.begin_token_i].should_outline then
        lines[#lines + 1] = "end"
        lines[#lines + 1] = "while m[i] ~= 0 do"
        lines[#lines + 1] = "f" .. token.begin_token_i .. "()"
      end
      lines[#lines + 1] = "end"
    end
  end

  lines[#lines + 1] = [[a.nvim_out_write "\n"]]
  return lines
end

function M.source(lines, opts)
  vim.validate { { opts, "t", true } }
  opts = vim.tbl_extend("keep", opts or {}, {
    profile = false,
    compile = not opts or not opts.terminal,
    transpile = false,
  })
  vim.validate {
    { opts.profile, "b" },
    { opts.compile, "b" },
    { opts.transpile, "b" },
    { opts.terminal, "b", true },
  }

  if opts.compile and opts.terminal then
    error "Cannot run compiled brainfuck programs in a terminal yet"
  elseif opts.transpile and opts.terminal then
    error 'Option "transpile" cannot be used with "terminal"'
  end

  local profile
  if opts.profile then
    profile = function(f, action)
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
    profile = function(f)
      return f()
    end
  end

  local parsed = profile(function()
    local tokens, contained_loops = M.parse(lines)
    return { tokens = tokens, contained_loops = contained_loops }
  end, "Parsing")

  if opts.compile or opts.transpile then
    local transpiled = profile(function()
      return M.transpile(
        parsed.tokens,
        parsed.contained_loops,
        opts.memory_size
      )
    end, "Transpile to Lua")

    if opts.transpile then
      vim.cmd [[new +set\ filetype=lua]]
      api.nvim_buf_set_lines(0, 0, -1, true, transpiled)
    end

    if opts.compile then
      local info = profile(function()
        local program, err = loadstring(
          table.concat(transpiled, "\n"),
          "compiled brainfuck program"
        )
        return { program = program, err = err }
      end, "Lua loadstring()")
      if not info.program then
        error(
          "Lua loadstring() of transpiled program failed!"
            .. " This is probably a brainfuck.nvim bug. Details: "
            .. info.err
        )
      end

      profile(info.program, "Execution (compiled)")
    end
  else
    if opts.terminal then
      -- Terminal is non-blocking, so profile() won't work.
      M.interpret(parsed.tokens, opts)
    else
      profile(function()
        M.interpret(parsed.tokens, opts)
      end, "Execution (interpreted)")
    end
  end
end

return M
