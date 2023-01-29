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

" Source file.bf (:source could be used instead).
:BrainfuckSource file.bf

" Source file.bf and also show timing information.
:BrainfuckSource! file.bf

" Source file.bf and set the memory available to the interpreter to 100 bytes.
" Default is 30,000 bytes. The cursor wraps around if it goes out-of-bounds.
:BrainfuckSource file.bf memory_size=100
```

Brainfuck programs can also be interrupted by pressing `<C-c>`.

## Where can I find some Brainfuck programs?

[Daniel Cristofani's website](http://www.brainfuck.org/) has quite a few.

## Why did you make this?

🤷

Also, I like making [silly](https://github.com/seandewar/nvimesweeper)
[Neovim](https://github.com/seandewar/killersheep.nvim)
[plugins](https://github.com/seandewar/sigsegvim).
