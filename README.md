# brainfuck.nvim

Run [Brainfuck](https://en.wikipedia.org/wiki/Brainfuck) programs in
[Neovim](https://neovim.io/).

Install using your favourite package manager, then execute `:source <filename>`,
where `<filename>` uses the `.b`, `.bf` or `.brainfuck` extensions.

Alternatively, `:BrainfuckSource` can be used, which also allows you to source
from the current buffer (`:help :range`s are supported), among other things.
Examples:

```vim
" Source lines 1-3 from the current buffer.
:1,3BrainfuckSource

" Source file.bf (equivalent to `:source file.bf`).
:BrainfuckSource file.bf

" Source file.bf and also show timing information.
:BrainfuckSource! file.bf

" Source file.bf and set the memory available to the VM to 100 bytes.
" Default is 30KB. The VM's cursor wraps around if it goes out-of-bounds.
:BrainfuckSource file.bf memory_size=100

" Source file.bf without compiling it, interpreting the code instead.
" By default, sourced brainfuck programs are compiled to Lua programs, which
" typically run faster than using the interpreter.
:BrainfuckSource file.bf compile=false

" Transpile file.bf to Lua without running it. Open the result in a new buffer.
:BrainfuckSource file.bf compile=false transpile=true
```

Brainfuck programs can also be interrupted by pressing `<C-c>`.

## Where can I find some Brainfuck programs?

[Daniel Cristofani's website](http://www.brainfuck.org/) has quite a few.

## Why did you make this?

🤷

Also, I like making [silly](https://github.com/seandewar/nvimesweeper)
[Neovim](https://github.com/seandewar/killersheep.nvim)
[plugins](https://github.com/seandewar/sigsegvim).
