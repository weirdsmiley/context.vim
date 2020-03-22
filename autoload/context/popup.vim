let s:context_buffer_name = '<context.vim>'

function! context#popup#update_context() abort
    let [lines, base_line] = context#popup#get_context(w:context.top_line)
    call context#util#echof('> context#popup#update_context', len(lines))

    let w:context.lines  = lines
    let w:context.indent = g:context.Border_indent(base_line)

    call context#util#show_cursor()
    call s:show()
endfunction

" returns [lines, base_line_nr]
function! context#popup#get_context(base_line) abort
    " NOTE: there's a problem if some of the hidden lines
    " (behind the popup) are wrapped. then our calculations are off
    " TODO: fix that?

    " a skipped line has the same context as the next unskipped one below
    let skipped       =  0
    let context_count =  0 " how many contexts did we check?
    let line_offset   = -1 " first iteration starts with zero

    while 1
        let line_offset += 1
        let line_number = a:base_line + line_offset

        let indent = g:context.Indent(line_number) "    -1 for invalid lines
        let line = getline(line_number)            " empty for invalid lines
        let base_line = context#line#make(line_number, indent, line)

        if base_line.indent < 0
            let lines = []
        elseif context#line#should_skip(line)
            let skipped += 1
            continue
        else
            let lines = context#context#get(base_line)
            " call context#util#echof('context#get', base_line.number, len(lines))
        endif

        let line_count = len(lines)
        call context#util#echof('got', line_offset, line_count, skipped)

        if line_count == 0 && context_count == 0
            " if we get an empty context on the first non skipped line
            return [[], 0]
        endif
        let context_count += 1

        " this context fits, use it
        if line_count < line_offset
            break
        endif

        if w:context_temp == 'scroll' && line_number >= w:context.cursor_line
            " if we want to show the cursor by scrolling and we reached the
            " cursor line, we don't need to check lower lines because the
            " cursor line will be visible, so this is the proper context
            call context#util#echof('skip cursor line')
            break
        endif

        " try again on next line if this context doesn't fit
        let skipped = 0
    endwhile

    if context_count == 0
        " we got here because we ran into the cursor line before we found any
        " context. now we need to scan upwards (from above top line) until we
        " find a line with a context and use that one.

        let skipped     = 0
        let line_offset = 0 " first iteration starts with -1

        while 1
            let line_offset -= 1
            let line_number = a:base_line + line_offset
            let indent = g:context.Indent(line_number) "    -1 for invalid lines
            let line = getline(line_number)            " empty for invalid lines
            let base_line = context#line#make(line_number, indent, line)

            call context#util#echof('checking above', line_offset, line_number)

            if base_line.indent < 0
                let lines = []
                call context#util#echof('reached nan')
            elseif context#line#should_skip(line)
                let skipped += 1
                continue
            else
                let lines = context#context#get(base_line)
                call context#util#echof('got', len(lines))
            endif

            break
        endwhile
    endif

    " NOTE: this overwrites lines, from here on out it's just a list of string
    call map(lines, function('context#line#display'))

    " success, we found a fitting context
    while len(lines) < line_offset - skipped - 1
        call add(lines, '')
    endwhile

    call add(lines, '') " will be replaced with border line
    return [lines, line_number]
endfunction

function! context#popup#layout() abort
    call context#util#echof('> context#popup#layout')

    for winid in keys(g:context.popups)
        let popup = g:context.popups[winid]
        let winbuf = winbufnr(winid)
        let popupbuf = winbufnr(popup)

        if winbuf == -1 || popupbuf == -1
            if popupbuf != -1
                call s:close(popup)
            endif
            call remove(g:context.popups, winid)
            continue
        endif

        call context#util#update_window_state(winid)

        " NOTE: the context might be wrong as the top line might have
        " changed, but we can't really fix that (without temporarily
        " moving the cursor which we'd like to avoid)
        " TODO: fix that?
        call context#popup#redraw(winid, 1)
    endfor
endfunction

function! context#popup#redraw(winid, force) abort
    let popup = get(g:context.popups, a:winid)
    if popup == 0
        return
    endif

    let c = getwinvar(a:winid, 'context', {})
    if c == {}
        return
    endif

    let lines = c.lines
    if len(lines) == 0
        return
    endif

    " check where to put the context, prefer top, but switch to bottom if
    " cursor is too high. abort if popup doesn't have to move and no a:force
    " is given
    if !a:force && c.popup_offset == 0
        call context#util#echof('  > context#popup#redraw no force skip top')
        return
    endif

    let lines = c.lines
    if len(lines) > 0
        let lines[-1] = s:get_border_line(a:winid, 1)
        let c.lines = lines
    endif

    let c.popup_offset = 0

    call context#util#echof('  > context#popup#redraw', len(lines))
    if g:context.presenter == 'nvim-float'
        call context#popup#nvim#redraw(a:winid, popup, lines)
    elseif g:context.presenter == 'vim-popup'
        call context#popup#vim#redraw(a:winid, popup, lines)
    endif
endfunction

" close all popups
function! context#popup#clear() abort
    for key in keys(g:context.popups)
        call s:close(g:context.popups[key])
    endfor
    let g:context.popups = {}
endfunction

" close current popup
function! context#popup#close() abort
    let winid = win_getid()
    let popup = get(g:context.popups, winid)
    if popup == 0
        return
    endif

    call s:close(popup)
    call remove(g:context.popups, winid)
endfunction

" popup related
function! s:show() abort
    let winid = win_getid()
    let popup = get(g:context.popups, winid)
    let popupbuf = winbufnr(popup)

    if popup > 0 && popupbuf == -1
        let popup = 0
        call remove(g:context.popups, winid)
    endif

    if len(w:context.lines) == 0
        call context#util#echof('  no lines')

        " if there are no lines, we reset popup_offset here so we'll try to
        " show the next non empty context at the top again
        let w:context.popup_offset = 0

        if popup > 0
            call s:close(popup)
            call remove(g:context.popups, winid)
        endif
        return
    endif

    if popup == 0
        let popup = s:open()
        let g:context.popups[winid] = popup
    endif

    call context#popup#redraw(winid, 1)

    if g:context.presenter == 'nvim-float'
        call context#popup#nvim#redraw_screen()
    endif
endfunction

function! s:open() abort
    call context#util#echof('  > open')
    if g:context.presenter == 'nvim-float'
        let popup = context#popup#nvim#open()
    elseif g:context.presenter == 'vim-popup'
        let popup = context#popup#vim#open()
    endif

    " NOTE: we use a non breaking space here again before the buffer name
    let border = ' *' .g:context.char_border . '* ' . s:context_buffer_name . ' '
    let tag = s:context_buffer_name
    call matchadd(g:context.highlight_border, border, 10, -1, {'window': popup})
    call matchadd(g:context.highlight_tag,    tag,    10, -1, {'window': popup})

    let buf = winbufnr(popup)
    call setbufvar(buf, '&syntax', &syntax)

    return popup
endfunction

function! s:close(popup) abort
    call context#util#echof('  > close')
    if g:context.presenter == 'nvim-float'
        call context#popup#nvim#close(a:popup)
    elseif g:context.presenter == 'vim-popup'
        call context#popup#vim#close(a:popup)
    endif
endfunction

function! s:get_border_line(winid, indent) abort
    let c = getwinvar(a:winid, 'context')
    let indent = a:indent ? c.indent : 0

    let line_len = c.size_w - indent - len(s:context_buffer_name) - 2 - c.padding
    " NOTE: we use a non breaking space before the buffer name because there
    " can be some display issues in the Kitty terminal with a normal space
    return ''
                \ . repeat(' ', indent)
                \ . repeat(g:context.char_border, line_len)
                \ . ' '
                \ . s:context_buffer_name
                \ . ' '
endfunction
