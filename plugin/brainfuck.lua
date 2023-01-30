local api = vim.api

api.nvim_create_autocmd("SourceCmd", {
  pattern = { "*.b", "*.bf", "*.brainfuck" },
  group = api.nvim_create_augroup("brainfuck", {}),
  callback = function(info)
    require("brainfuck").source(io.lines(info.file))
  end,
})

api.nvim_create_user_command("BrainfuckSource", function(info)
  local opts = { profile = info.bang }
  local file

  local function toboolean(string)
    if string == "true" then
      return true
    elseif string == "false" then
      return false
    end
  end

  for _, arg in ipairs(info.fargs) do
    local option, value = arg:match "^(.*)=(.*)$"
    if not option then
      if file then
        error "More than one file name was specified"
      end
      file = arg
    elseif option == "memory_size" then
      opts.memory_size = tonumber(value)
      if not opts.memory_size then
        error 'Option "memory_size" needs a number value'
      end
    elseif option == "compile" then
      opts.compile = toboolean(value)
      if opts.compile == nil then
        error 'Option "compile" needs a boolean value'
      end
    elseif option == "transpile" then
      opts.transpile = toboolean(value)
      if opts.transpile == nil then
        error 'Option "transpile" needs a boolean value'
      end
    else
      error('Unknown option: "' .. option .. '"')
    end
  end

  if file then
    require("brainfuck").source(io.lines(file), opts)
  else
    -- Source from curbuf instead, like `:source`.
    require("brainfuck").source(
      api.nvim_buf_get_lines(0, info.line1 - 1, info.line2, false),
      opts
    )
  end
end, { bang = true, nargs = "*", range = "%", bar = true, complete = "file" })
