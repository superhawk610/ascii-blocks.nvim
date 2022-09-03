if exists('g:ascii_blocks_loaded')
  finish
endif

let g:ascii_blocks_loaded = v:true

command AsciiBlockify :call ascii_blocks#transform_selection()
