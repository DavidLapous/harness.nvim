-- Run: nvim --headless -n -i NONE -u NONE -l tests/fuzz.lua
-- Optional HARNESS_TARGET=/path/init.lua, FUZZ_SEED=21102026, FUZZ_ITERS=2000, FUZZ_RESULTS=/path/out.json.
-- No real AI CLI, network, config, or plugin files are modified. Real Neovim
-- buffers, visual selections, windows and PTY jobs; controlled Snacks/CLI callbacks.
local script_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local repo_root = vim.fn.fnamemodify(script_dir, ':h')
local default_target = repo_root .. '/lua/harness/init.lua'
if not loadfile(default_target) then
  default_target = script_dir .. '/lua/harness/init.lua'
end
local targets = vim.env.HARNESS_TARGET and { vim.env.HARNESS_TARGET } or { default_target }
local seed = tonumber(vim.env.FUZZ_SEED) or 21102026
local iterations = tonumber(vim.env.FUZZ_ITERS) or 2000
math.randomseed(seed)
local original = {
  system = vim.system, schedule = vim.schedule, defer = vim.defer_fn,
  notify = vim.notify, input = vim.ui.input, select = vim.ui.select,
  send = vim.api.nvim_chan_send, executable = vim.fn.executable,
}
local results, counts = {}, { pass = 0, fail = 0 }
local active_target
local function eq(actual, expected, context)
  assert(vim.deep_equal(actual, expected), (context or '') .. '\nexpected ' .. vim.inspect(expected) .. '\nactual   ' .. vim.inspect(actual))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  counts[ok and 'pass' or 'fail'] = counts[ok and 'pass' or 'fail'] + 1
  results[#results + 1] = { target = active_target, name = name, ok = ok, error = ok and nil or err }
  print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or '\n' .. err))
end
local function up(fn, name)
  for i = 1, 100 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then return value end
  end
  error('missing upvalue ' .. name)
end
local channels, buffers = {}, {}
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
local source_win = vim.api.nvim_get_current_win()
for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex', 'claude' }) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local chan = vim.fn.jobstart({ '/bin/cat' }, { term = true })
  assert(chan > 0, 'PTY creation failed')
  vim.b[buf].snacks_terminal = { cmd = name }
  channels[name], buffers[name] = chan, buf
end
vim.api.nvim_set_current_buf(source)
local state
local function normal(keys)
  vim.cmd.normal({ args = { keys }, bang = true })
end
local function reset_source(lines, row, col)
  normal('\27')
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_buf(source_win, source)
  vim.bo[source].modifiable = true
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines or { 'alpha beta alpha' })
  vim.api.nvim_win_set_cursor(source_win, { row or 1, col or 0 })
  vim.o.selection = 'inclusive'
  vim.o.virtualedit = ''
end
local function fresh(name)
  if state then
    for _, t in pairs(state.terms) do
      if t.win and vim.api.nvim_win_is_valid(t.win) then vim.api.nvim_win_close(t.win, true) end
    end
  end
  reset_source()
  state = { terms = {}, sends = {}, deferred = {}, scheduled = {}, systems = {},
    inputs = {}, selects = {}, notices = {}, get_calls = {}, kitty_writes = {}, executable = true }
  local s = state
  vim.notify = function(msg, level) s.notices[#s.notices + 1] = { msg = msg, level = level } end
  vim.ui.input = function(opts, cb) s.inputs[#s.inputs + 1] = { opts = opts, cb = cb } end
  vim.ui.select = function(items, opts, cb)
    for _, item in ipairs(items) do assert(type(opts.format_item(item)) == 'string') end
    s.selects[#s.selects + 1] = { items = items, opts = opts, cb = cb }
  end
  vim.schedule = function(cb) s.scheduled[#s.scheduled + 1] = cb end
  vim.defer_fn = function(cb, ms) s.deferred[#s.deferred + 1] = { cb = cb, ms = ms } end
  vim.system = function(cmd, opts, cb)
    if s.spawn_error then error('spawn failure') end
    s.systems[#s.systems + 1] = { cmd = cmd, opts = opts, cb = cb }
    return { pid = 999999 }
  end
  vim.fn.executable = function() return s.executable and 1 or 0 end
  vim.api.nvim_chan_send = function(chan, bytes)
    if s.send_error then error('send failure') end
    s.sends[#s.sends + 1] = { chan = chan, bytes = bytes }
    if s.real_send then return original.send(chan, bytes) end
    return #bytes
  end
  package.loaded['snacks.image.terminal'] = {
    write = function(data) s.kitty_writes[#s.kitty_writes + 1] = data end,
  }
  local function get(cmd, opts)
    s.get_calls[#s.get_calls + 1] = { cmd = cmd, opts = vim.deepcopy(opts) }
    if s.get_error then error('terminal creation failure') end
    if s.lookup_missing and opts.create == false then return nil end
    local t = s.terms[cmd]
    if not t and opts.create ~= false then
      t = { buf = buffers[cmd], cmd = cmd }
      function t:valid() return self.win ~= nil and vim.api.nvim_win_is_valid(self.win) end
      function t:show()
        if not self:valid() then
          self.win = vim.api.nvim_open_win(self.buf, false, { relative = 'editor', row = 0, col = 0,
            width = 30, height = 5, style = 'minimal' })
        end
      end
      function t:hide()
        if self:valid() then vim.api.nvim_win_close(self.win, true) end
        self.win = nil
      end
      s.terms[cmd] = t
      t:show()
    end
    return t
  end
  package.loaded['snacks.terminal'] = {
    get = get,
    toggle = function(cmd, opts)
      s.last_toggle_opts = vim.deepcopy(opts)
      local t = s.terms[cmd]
      if not t then get(cmd, opts) elseif t:valid() then t:hide() else t:show() end
    end,
  }
  local h = assert(loadfile(active_target))()
  h.setup({ default = name, preload_models = false })
  return h, s
end
local function drain(queue)
  while #queue > 0 do
    local item = table.remove(queue, 1)
    if type(item) == 'table' then item.cb() else item() end
  end
end
local function catalog(name, id)
  local m = name == 'omp' and { provider = 'provider', id = id or 'model', thinking = { 'low', 'high' } }
    or { id = id or 'gemini-pro-high', label = 'Gemini' }
  return vim.json.encode({ models = { m } })
end
local function complete(s, index, stdout, code, stderr)
  assert(s.systems[index], 'missing system request ' .. index).cb({ code = code or 0, stdout = stdout, stderr = stderr or '' })
  drain(s.scheduled)
end
local function body(s, index)
  local bytes = assert(s.sends[index or #s.sends], 'no bytes sent').bytes
  return bytes:match('^\27%[200~(.*)\27%[201~$') or bytes
end
local function ordinal(n)
  local mod = n % 100
  return tostring(n) .. ((mod >= 11 and mod <= 13) and 'th' or ({ 'st', 'nd', 'rd' })[n % 10] or 'th')
end
-- Independent oracle: character indexing via strcharpart, not str_utf_pos;
-- enumerate maximal class-2 runs and count exact token equality.
local function oracle(line, col, selected, selected_start)
  local words, token, byte = {}, nil, 1
  for i = 0, vim.fn.strchars(line) - 1 do
    local ch = vim.fn.strcharpart(line, i, 1)
    if #ch > 1 and vim.fn.strchars(' ' .. ch, 1) == 1 then
      if token then token.text, token.finish = token.text .. ch, byte + #ch - 1 end
    elseif vim.fn.charclass(ch) == 2 then
      if not token then token = { text = '', start = byte }; words[#words + 1] = token end
      token.text, token.finish = token.text .. ch, byte + #ch - 1
    else token = nil end
    byte = byte + #ch
  end
  local target = selected_start or col
  local current
  for _, word in ipairs(words) do if word.start <= target and target <= word.finish then current = word end end
  local count, index, text = 0, 0, selected or (current and current.text)
  if selected and selected:match('^%s*$') then return ':' .. target end
  if selected and current and selected_start + #selected - 1 <= current.finish then
    if current.start ~= selected_start or current.text ~= selected or selected:match('^%d') then
      return ':' .. target
    end
    for _, word in ipairs(words) do
      if word.text == text then count = count + 1; if word == current then index = count end end
    end
  elseif selected then
    for at = 1, #line do
      if line:sub(at, at + #selected - 1) == selected then
        count = count + 1
        if at == selected_start then index = count end
      end
    end
    if index == 0 then return ':' .. target end
  else
    if not current or current.text:match('^%d') then return ':' .. col end
    for _, word in ipairs(words) do
      if word.text == text then count = count + 1; if word == current then index = count end end
    end
  end
  return ' at ' .. (count > 1 and ordinal(index) .. ' ' or '') .. '"' .. text .. '"'
end
-- Independent oracle for the characterwise Visual pointer: characters via
-- strcharpart/char2nr (not str_utf_pos/byte decoding), full selected text from
-- an actual Visual yank instead of windowed buffer reads.
local function chars_of(s)
  local t = {}
  for i = 0, vim.fn.strchars(s) - 1 do t[#t + 1] = vim.fn.strcharpart(s, i, 1) end
  return t
end
local named_escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\t'] = '\\t', ['\n'] = '\\n', ['\r'] = '\\r' }
local function oracle_quote(s)
  local out = {}
  for _, ch in ipairs(chars_of(s)) do
    local cp = vim.fn.char2nr(ch)
    out[#out + 1] = named_escapes[ch] or ((cp < 32 or cp == 127) and ('\\x%02x'):format(cp))
      or (((cp >= 0x80 and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029) and ('\\u%04x'):format(cp)) or ch
  end
  return '"' .. table.concat(out) .. '"'
end
local function oracle_pointer(name, sl, sc, el, ec, text, modified)
  local head = name .. ':' .. sl .. ':' .. sc .. '-' .. (el ~= sl and (el .. ':') or '') .. ec
    .. (modified and ' [unsaved]' or '')
  local t = chars_of(text)
  if sl == el then
    if #t <= 48 then return head .. ' ' .. oracle_quote(text) end
    return head .. ' ' .. oracle_quote(table.concat(t, '', 1, 24)) .. '…' .. oracle_quote(table.concat(t, '', #t - 23))
  end
  local first, start_anchor = text:match('^[^\n]*'), oracle_quote('\n')
  if first ~= '' then
    local f = chars_of(first)
    local s = table.concat(f, '', 1, math.min(#f, 24))
    local trimmed = s:gsub('%s+$', '')
    start_anchor = oracle_quote(trimmed ~= '' and trimmed or s) .. (#f > 24 and '…' or '')
  end
  local nl = text:sub(-1) == '\n' and '\n' or ''
  local last = chars_of((nl == '' and text or text:sub(1, -2)):match('[^\n]*$') .. nl)
  local s = table.concat(last, '', math.max(1, #last - 23))
  local trimmed = s:gsub('^%s+', '')
  return head .. ' from ' .. start_anchor .. ' to ' .. (#last > 24 and '…' or '') .. oracle_quote(trimmed ~= '' and trimmed or s)
end
-- Cursor positions reachable in real Visual mode: starts of characters with
-- their composing characters (byteidx counts those with the base character).
local function grapheme_starts(line)
  local t = {}
  for i = 0, vim.fn.strchars(line, 1) - 1 do t[#t + 1] = vim.fn.byteidx(line, i) + 1 end
  return #t > 0 and t or { 1 }
end
-- Check a characterwise Visual ask() prompt against the same selection yanked
-- in real Visual mode (`gv` reselects it after ask() leaves Visual mode).
local function check_charwise(prompt, context, reselect)
  local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  if reselect then reselect() else normal('gv') end
  vim.cmd.normal({ args = { 'y' }, bang = true, mods = { silent = true } })
  local yank, mark = vim.fn.getreg('"'), vim.fn.getpos("'[")
  local ctx = '\n' .. (context or '') .. ' ' .. vim.o.selection .. ' ' .. vim.inspect(lines) .. ' ' .. vim.inspect(prompt)
  if yank == '' then
    assert(not prompt:find('^%[No Name%]:%d+:%d+%-'), 'empty region must keep legacy pointer' .. ctx)
    return
  end
  local sl, sc, el, ec = prompt:match('^%[No Name%]:(%d+):(%d+)%-(%d+):(%d+) ')
  if not sl then
    sl, sc, ec = prompt:match('^%[No Name%]:(%d+):(%d+)%-(%d+) ')
    el = sl
  end
  assert(sl, 'missing exact range' .. ctx)
  sl, sc, el, ec = tonumber(sl), tonumber(sc), tonumber(el), tonumber(ec)
  local parts = {}
  for l = sl, el do
    local s = lines[l] .. (l < #lines and '\n' or '')
    parts[#parts + 1] = s:sub(l == sl and sc or 1, l == el and ec or -1)
  end
  eq(table.concat(parts), yank, 'range bytes differ from Visual yank' .. ctx)
  -- '[ is the yank start, clamped to the last character when the start is a line break.
  local len = #lines[sl]
  eq({ mark[2], mark[3] == sc or (sc == len + 1 and mark[3] == math.max(len, 1)) }, { sl, true }, 'start mark' .. ctx)
  eq(prompt, oracle_pointer('[No Name]', sl, sc, el, ec, yank, vim.bo[source].modified) .. ': ', 'hint' .. ctx)
end
local atoms = { 'a', 'Z', '_', '0', '9', ' ', '\t', '%', '^', '$', '(', ')', '.', '[', ']', '*', '+', '-', '?',
  'é', '界', 'α', 'Ж', '🙂', '𝛼', 'é', '́', '中', 'ß', '́́' }
local function random_line(n)
  local t = {}
  for _ = 1, n or math.random(0, 50) do t[#t + 1] = atoms[math.random(#atoms)] end
  return table.concat(t)
end
for _, target in ipairs(targets) do
  active_target = target
  print('\nTARGET ' .. target .. ' SEED ' .. seed .. ' ITERS ' .. iterations)
  for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex', 'claude' }) do
    test(name .. ': setup/switch/hide/toggle/current/focus', function()
      local h, s = fresh(name)
      eq(h.current(), name)
      h.switch(name)
      eq(s.terms[name]:valid(), true)
      eq(vim.api.nvim_get_current_win(), s.terms[name].win)
      h.toggle(); eq(s.terms[name]:valid(), false)
      h.toggle(); eq(s.terms[name]:valid(), true)
      for _, next_name in ipairs({ 'codex', 'claude', 'omp', 'agy', 'opencode', name }) do
        h.switch(next_name); eq(h.current(), next_name)
        for other, t in pairs(s.terms) do eq(t:valid(), other == next_name) end
      end
      h.setup({ win = { width = 0.25 }, preload_models = false })
      h.toggle(); h.toggle()
      eq(s.last_toggle_opts.win.width, 0.25)
      h.switch('bogus'); eq(h.current(), name)
    end)
    test(name .. ': ask submit/cancel/sanitize/deferred CR', function()
      local h, s = fresh(name)
      h.ask(); eq(s.inputs[1].opts.default, '[No Name]:1 at 1st "alpha": ')
      s.inputs[1].cb(nil); s.inputs[1].cb(' \t '); eq(#s.sends, 0)
      s.inputs[1].cb('hello\27[201~world\27[200~')
      eq(body(s), 'helloworld'); eq(s.sends[1].chan, channels[name])
      eq(#s.deferred, 1); eq(s.deferred[1].ms, 30)
      drain(s.deferred); eq(s.sends[2].bytes, '\r')
    end)
    test(name .. ': BUG nested paste delimiters must not escape composer', function()
      local h, s = fresh(name)
      h.ask()
      s.inputs[1].cb('\27[\27[200~201~\rUNINTENDED_SUBMIT')
      local payload = body(s)
      assert(not payload:find('\27[201~', 1, true),
        'sanitization created a live paste terminator: ' .. vim.inspect(payload))
    end)
    test(name .. ': prompt_range fences/no-submit/operator marks', function()
      local h, s = fresh(name)
      reset_source({ 'a ``` b', '````', 'tail' })
      vim.bo[source].filetype = 'lua'
      h.prompt_range(1, 2)
      eq(body(s), '[No Name]:1-2\n`````lua\na ``` b\n````\n`````\n\n')
      eq(#s.deferred, 0)
      vim.api.nvim_buf_set_mark(source, '[', 2, 0, {})
      vim.api.nvim_buf_set_mark(source, ']', 3, 0, {})
      h.operator(); assert(body(s):find('[No Name]:2-3', 1, true))
      eq(h.send_operator(), 'g@'); eq(h.send_line(), 'g@_')
      eq(vim.go.operatorfunc, "v:lua.require'harness'.operator")
    end)
    test(name .. ': model picker/cancellation/focus and thinking', function()
      local h, s = fresh(name)
      h.switch(name)
      s.terms[name]:hide()
      vim.api.nvim_set_current_win(source_win)
      h.pick_model()
      if name == 'omp' or name == 'agy' then
        eq(#s.systems, 1)
        complete(s, 1, catalog(name))
        local picker = s.selects[1]; assert(#picker.items > 0)
        picker.cb(nil); eq(#s.sends, 0)
        picker.cb(picker.items[1]); eq(body(s), name == 'omp' and '/switch provider/model:low' or '/model gemini-pro-high')
      else
        eq(body(s), name == 'opencode' and '/models' or '/model')
        eq(s.terms[name]:valid(), true)
        eq(vim.api.nvim_get_current_win(), s.terms[name].win)
      end
      drain(s.deferred)
      h.cycle_thinking()
      eq(body(s), ({ omp = '\27[Z', agy = '/effort xhigh', opencode = '\20', codex = '/model', claude = '/effort' })[name])
      if name == 'agy' then
        h.cycle_thinking('backward'); eq(body(s), '/effort high')
        for _ = 1, 6 do h.cycle_thinking() end
        eq(body(s), '/effort high')
      end
    end)
    test(name .. ': pick_thinking dropdown/cancellation/sync', function()
      local h, s = fresh(name)
      h.switch(name)
      s.terms[name]:hide()
      vim.api.nvim_set_current_win(source_win)
      h.pick_thinking()
      if name == 'omp' or name == 'agy' then
        local picker = s.selects[#s.selects]
        assert(#picker.items == (name == 'omp' and 8 or 6))
        picker.cb(nil); eq(#s.sends, 0)
        picker.cb(picker.items[#picker.items])
        eq(body(s), name == 'omp' and '/effort auto' or '/effort max')
        drain(s.deferred)
        eq(s.sends[#s.sends].bytes, '\r')
        if name == 'agy' then
          h.cycle_thinking()
          eq(body(s), '/effort minimal')
        end
      elseif name == 'codex' or name == 'claude' then
        eq(body(s), name == 'claude' and '/effort' or '/model')
        eq(s.terms[name]:valid(), true)
        eq(vim.api.nvim_get_current_win(), s.terms[name].win)
      else
        eq(body(s), '\20')
      end
    end)
    test(name .. ': no terminal/failed send/invalid buffer', function()
      local h, s = fresh(name)
      -- Prevent global fallback matches for this harness.
      local metadata = vim.b[buffers[name]].snacks_terminal
      vim.b[buffers[name]].snacks_terminal = nil
      h.prompt_range(1); eq(#s.sends, 0); assert(s.notices[#s.notices].msg:find('no running', 1, true))
      vim.b[buffers[name]].snacks_terminal = metadata
      h.switch(name); s.send_error = true
      h.prompt_range(1); eq(#s.sends, 0); assert(s.notices[#s.notices].msg:find('send failure', 1, true))
      s.send_error = nil
      s.terms[name].buf = -99
      h.prompt_range(1); eq(#s.sends, 1) -- fallback to real terminal metadata
    end)
  end
  test('no selection, dropdown accept/cancel, missing Snacks, preload', function()
    local h, s = fresh()
    eq(h.current(), nil)
    h.ask(); h.prompt_range(); h.pick_model(); h.pick_thinking(); h.cycle_thinking(); eq(#s.notices, 5)
    h.toggle(); s.selects[1].cb(nil); eq(h.current(), nil)
    h.switch()
    local claude
    for _, item in ipairs(s.selects[2].items) do
      if item.name == 'claude' then claude = item end
    end
    assert(claude, 'Claude Code missing from harness picker')
    s.selects[2].cb(claude); eq(h.current(), 'claude'); eq(s.terms.claude:valid(), true)
    h.setup({ preload_models = true }); eq(#s.systems, 2)
    h.setup({ preload_models = true }); eq(#s.systems, 2)
    local saved = package.loaded['snacks.terminal']
    package.loaded['snacks.terminal'] = nil
    package.preload['snacks.terminal'] = function() error('missing Snacks') end
    h.switch('omp'); eq(h.current(), 'claude')
    package.loaded['snacks.terminal'] = saved; package.preload['snacks.terminal'] = nil
  end)
  test('TermRequest Kitty graphics APC passthrough and placement_id normalization', function()
    local _, s = fresh('omp')
    eq(vim.env.PI_FORCE_IMAGE_PROTOCOL, 'kitty')
    eq(vim.env.PI_KITTY_PLACEHOLDERS, '1')
    vim.api.nvim_exec_autocmds('TermRequest', { data = { sequence = '\27_Ga=t,f=100,q=2,i=9;iVBOR,p=42w0KGgo=' } })
    vim.api.nvim_exec_autocmds('TermRequest', { data = { sequence = '\27_Ga=p,U=1,q=2,i=9,p=3,c=12,r=4' } })
    vim.api.nvim_exec_autocmds('TermRequest', { data = { sequence = '\27_Ga=d,d=i,i=9,p=3,q=2' } })
    vim.api.nvim_exec_autocmds('TermRequest', { data = { sequence = '\27P>|ghostty 1.1.0' } })
    eq(s.kitty_writes, {
      '\27_Ga=t,f=100,q=2,i=9;iVBOR,p=42w0KGgo=\27\\',
      '\27_Ga=p,U=1,q=2,i=9,c=12,r=4\27\\',
      '\27_Ga=d,d=i,i=9,q=2\27\\',
    })
  end)
  test('bottom/right/left/top panel position commands and focus preservation', function()
    local h, s = fresh('omp')
    h.switch('omp')
    local t = s.terms.omp
    t.opts = { position = 'right', wo = { winfixheight = false, winfixwidth = true } }
    vim.api.nvim_set_current_win(source_win)
    for _, spec in ipairs({
      { fn = 'bottom', pos = 'bottom', v = false },
      { fn = 'right', pos = 'right', v = true },
      { fn = 'left', pos = 'left', v = true },
      { fn = 'top', pos = 'top', v = false },
    }) do
      h[spec.fn]()
      eq(t.opts.position, spec.pos)
      eq(t.opts.wo.winfixwidth, spec.v)
      eq(t.opts.wo.winfixheight, not spec.v)
      eq(t:valid(), true)
      eq(vim.api.nvim_get_current_win(), source_win)
      eq(s.notices[#s.notices].msg, '[ai] panel → ' .. spec.pos)
    end
    vim.api.nvim_set_current_win(t.win)
    h.bottom()
    eq(vim.api.nvim_get_current_win(), t.win)
    vim.api.nvim_set_current_win(source_win)
  end)
  test('line_locator independent Unicode/token/selection oracle fuzz', function()
    local h = fresh('omp')
    local locator = up(h.ask, 'line_locator')
    for i = 1, iterations do
      local line = random_line()
      local positions = vim.str_utf_pos(line)
      local col = #positions > 0 and positions[math.random(#positions)] or 1
      eq(locator(line, col), oracle(line, col), 'normal fuzz case ' .. i .. ' ' .. vim.inspect(line) .. ':' .. col)
      if #positions > 0 then
        local a, b = math.random(#positions), math.random(#positions)
        if a > b then a, b = b, a end
        local start = positions[a]
        local selected = line:sub(start, (positions[b + 1] or (#line + 1)) - 1)
        eq(locator(line, col, selected, start), oracle(line, col, selected, start), 'selection fuzz ' .. i)
      end
    end
    for n = 1, 125 do
      local line = string.rep('word ', n)
      eq(locator(line, (n - 1) * 5 + 1), n == 1 and ' at "word"' or ' at ' .. ordinal(n) .. ' "word"')
    end
    for _, magic in ipairs({ '%', '^', '$', '(', ')', '.', '[', ']', '*', '+', '-', '?' }) do
      eq(locator(magic .. ' ' .. magic, 3, magic, 3), ' at 2nd "' .. magic .. '"')
    end
  end)
  test('BUG Unicode combining marks must stay with preceding grapheme', function()
    local h, s = fresh('omp')
    local locator = up(h.ask, 'line_locator')
    local line = '界́x'
    -- Byte 6 is ASCII x. The acute accent belongs to the preceding CJK glyph.
    local actual_locator = locator(line, 6)
    reset_source({ line }, 1, 5)
    h.ask()
    eq({ actual_locator, s.inputs[1].opts.default }, { ' at "x"', '[No Name]:1 at "x": ' })
  end)
  test('ask normal ASCII/Unicode/empty/long fuzz', function()
    local h, s = fresh('omp')
    for i = 1, iterations do
      local line = random_line(i % 100 == 0 and 500 or nil)
      reset_source({ line })
      local pos = vim.str_utf_pos(line)
      local col = #pos > 0 and pos[math.random(#pos)] or 1
      vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
      h.ask()
      local actual_col = vim.api.nvim_win_get_cursor(0)[2] + 1
      eq(s.inputs[#s.inputs].opts.default, '[No Name]:1' .. oracle(line, actual_col) .. ': ', 'ask fuzz ' .. i)
    end
    for _, line in ipairs({ '', '\t', string.rep('x', 100000), string.rep('é ', 5000) }) do
      reset_source({ line }); h.ask()
      assert(type(s.inputs[#s.inputs].opts.default) == 'string')
    end
  end)
  test('ask actual visual v forward/backward/V/block and multiline fuzz', function()
    local h, s = fresh('omp')
    for i = 1, math.floor(iterations / 4) do
      local line = random_line(math.random(1, 50))
      reset_source({ line, 'second row' })
      local positions = vim.str_utf_pos(line)
      if #positions > 0 then
        local a, b = positions[math.random(#positions)], positions[math.random(#positions)]
        local mode = ({ 'v', 'v', 'V', '\22' })[(i % 4) + 1]
        vim.api.nvim_win_set_cursor(0, { 1, a - 1 }); normal(mode)
        vim.api.nvim_win_set_cursor(0, { 1, b - 1 })
        eq(vim.fn.mode(), mode)
        local start = math.min(vim.fn.col('v'), vim.fn.col('.'))
        local selected = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode })[1]
        local col = vim.fn.col('.')
        h.ask()
        eq(vim.fn.mode(), 'n')
        if mode == 'v' then
          -- Recreate the same API-placed Visual selection (possibly on a composing
          -- character, which `gv` would normalize) and compare with its direct yank.
          check_charwise(s.inputs[#s.inputs].opts.default, 'visual fuzz ' .. i, function()
            vim.api.nvim_win_set_cursor(0, { 1, a - 1 }); normal('v')
            vim.api.nvim_win_set_cursor(0, { 1, b - 1 })
          end)
        else
          local expected = mode == 'V' and '[No Name]:1: ' or '[No Name]:1' .. oracle(line, col, selected, start) .. ': '
          eq(s.inputs[#s.inputs].opts.default, expected, 'visual fuzz ' .. i .. ' ' .. vim.inspect(line))
        end
      end
    end
    for _, mode in ipairs({ 'v', 'V', '\22' }) do
      for _, backward in ipairs({ false, true }) do
        reset_source({ 'alpha', 'beta', 'gamma' }, backward and 3 or 1)
        normal(mode); vim.api.nvim_win_set_cursor(0, { backward and 1 or 3, 0 })
        h.ask()
        eq(s.inputs[#s.inputs].opts.default, mode == 'v' and '[No Name]:1:1-3:1 [unsaved] from "alpha" to "g": '
          or '[No Name]:1-3: ')
      end
    end
  end)
  test('exclusive visual selection excludes right endpoint', function()
    local h, s = fresh('omp')
    reset_source({ 'alpha beta' })
    vim.o.selection = 'exclusive'
    normal('v'); vim.api.nvim_win_set_cursor(0, { 1, 5 })
    eq(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v', exclusive = true })[1], 'alpha')
    h.ask(); eq(s.inputs[1].opts.default, '[No Name]:1:1-5 [unsaved] "alpha": ')
    -- Blockwise keeps the legacy single-line locator.
    reset_source({ 'alpha beta' })
    vim.o.selection = 'exclusive'
    normal('\22'); vim.api.nvim_win_set_cursor(0, { 1, 5 })
    h.ask(); eq(s.inputs[2].opts.default, '[No Name]:1 at "alpha": ')
  end)
  test('ask charwise v pointer matches actual Visual yank (multiline fuzz)', function()
    local h, s = fresh('omp')
    for i = 1, math.floor(iterations / 4) do
      local lines = {}
      for k = 1, math.random(1, 4) do lines[k] = math.random(4) == 1 and '' or random_line(math.random(0, 60)) end
      reset_source(lines)
      vim.o.selection = math.random(2) == 1 and 'inclusive' or 'exclusive'
      if math.random(3) == 1 then vim.bo[source].modified = false end
      local function pick()
        local l = math.random(#lines)
        local starts = grapheme_starts(lines[l])
        return { l, starts[math.random(#starts)] - 1 }
      end
      vim.api.nvim_win_set_cursor(0, pick()); normal('v')
      vim.api.nvim_win_set_cursor(0, pick())
      local keys = ({ '', '', '$', 'o$o' })[math.random(4)]
      if keys ~= '' then normal(keys) end
      eq(vim.fn.mode(), 'v')
      h.ask()
      eq(vim.fn.mode(), 'n')
      check_charwise(s.inputs[#s.inputs].opts.default, 'charwise fuzz ' .. i .. ' keys=' .. keys)
    end
  end)
  test('ask charwise v exact pointers: repeated, reversed, exclusive, Unicode, line breaks', function()
    local h, s = fresh('omp')
    local function ask_v(lines, a, b, opts)
      opts = opts or {}
      reset_source(lines)
      vim.o.selection = opts.selection or 'inclusive'
      if opts.saved then vim.bo[source].modified = false end
      vim.api.nvim_win_set_cursor(0, a); normal('v'); vim.api.nvim_win_set_cursor(0, b)
      if opts.keys then normal(opts.keys) end
      h.ask()
      eq(vim.fn.mode(), 'n')
      local prompt = s.inputs[#s.inputs].opts.default
      if vim.o.selection ~= 'old' then check_charwise(prompt, vim.inspect({ a, b, opts })) end
      return prompt
    end
    -- Repeated text: coordinates disambiguate identical snippets; partial tokens keep exact bytes.
    eq(ask_v({ 'foo foo foo' }, { 1, 4 }, { 1, 6 }), '[No Name]:1:5-7 [unsaved] "foo": ')
    eq(ask_v({ 'foo foo foo' }, { 1, 6 }, { 1, 4 }), '[No Name]:1:5-7 [unsaved] "foo": ')
    eq(ask_v({ 'foo foo foo' }, { 1, 9 }, { 1, 10 }), '[No Name]:1:10-11 [unsaved] "oo": ')
    eq(ask_v({ 'let (a, b) = pair;' }, { 1, 5 }, { 1, 8 }, { saved = true }), '[No Name]:1:6-9 "a, b": ')
    -- Exclusive: the end character is excluded, equal endpoints select one character,
    -- and an end in column 1 keeps the previous line break.
    eq(ask_v({ 'alpha beta' }, { 1, 5 }, { 1, 0 }, { selection = 'exclusive' }), '[No Name]:1:1-5 [unsaved] "alpha": ')
    eq(ask_v({ 'alpha beta' }, { 1, 2 }, { 1, 2 }, { selection = 'exclusive' }), '[No Name]:1:3-3 [unsaved] "p": ')
    eq(ask_v({ 'alpha', 'beta' }, { 1, 2 }, { 2, 0 }, { selection = 'exclusive' }), '[No Name]:1:3-6 [unsaved] "pha\\n": ')
    eq(ask_v({ 'alpha', 'beta' }, { 2, 0 }, { 1, 2 }, { selection = 'exclusive' }), '[No Name]:1:3-6 [unsaved] "pha\\n": ')
    -- Unicode: a(1) é(2-3) 界(4-6) 🙂(7-10) b(11); the end covers every byte of its character.
    eq(ask_v({ 'aé界🙂b' }, { 1, 3 }, { 1, 6 }), '[No Name]:1:4-10 [unsaved] "界🙂": ')
    eq(ask_v({ 'aé界🙂b' }, { 1, 6 }, { 1, 3 }), '[No Name]:1:4-10 [unsaved] "界🙂": ')
    eq(ask_v({ 'aé界🙂b' }, { 1, 3 }, { 1, 6 }, { selection = 'exclusive' }), '[No Name]:1:4-6 [unsaved] "界": ')
    eq(ask_v({ 'aé界🙂b' }, { 1, 6 }, { 1, 6 }, { selection = 'exclusive' }), '[No Name]:1:7-10 [unsaved] "🙂": ')
    eq(ask_v({ 'é́x' }, { 1, 0 }, { 1, 0 }), '[No Name]:1:1-4 [unsaved] "é́": ')
    -- Line breaks are column (line length + 1); the buffer's last line break is never selected.
    eq(ask_v({ 'ab', 'cd' }, { 1, 0 }, { 1, 0 }, { keys = '$' }), '[No Name]:1:1-3 [unsaved] "ab\\n": ')
    eq(ask_v({ 'ab', 'cd' }, { 1, 0 }, { 1, 0 }, { keys = '$', selection = 'exclusive' }), '[No Name]:1:1-2 [unsaved] "ab": ')
    eq(ask_v({ 'ab', '', 'cd' }, { 2, 0 }, { 2, 0 }), '[No Name]:2:1-1 [unsaved] "\\n": ')
    eq(ask_v({ 'ab', '', 'cd' }, { 2, 0 }, { 2, 0 }, { selection = 'exclusive' }), '[No Name]:2:1-1 [unsaved] "\\n": ')
    eq(ask_v({ 'ab', '', 'cd' }, { 1, 1 }, { 2, 0 }), '[No Name]:1:2-2:1 [unsaved] from "b" to "\\n": ')
    eq(ask_v({ 'ab', 'cd' }, { 2, 0 }, { 2, 0 }, { keys = '$' }), '[No Name]:2:1-2 [unsaved] "cd": ')
    eq(ask_v({ 'ab', '' }, { 1, 1 }, { 2, 0 }), '[No Name]:1:2-3 [unsaved] "b\\n": ')
    eq(ask_v({ 'ab', '' }, { 2, 0 }, { 2, 0 }), '[No Name]:2:1: ') -- empty region: legacy pointer
    eq(ask_v({ 'ab', 'cd' }, { 1, 1 }, { 2, 0 }, { keys = 'o$o' }), '[No Name]:1:3-2:1 [unsaved] from "\\n" to "c": ')
    -- Multiline: exact endpoints; anchors are bounded and trimmed only on their open side.
    local code = { '    total = sort(runs, &cfg)   ', '    x = 1', '        limit + 1' }
    eq(ask_v(code, { 1, 12 }, { 3, 12 }), '[No Name]:1:13-3:13 [unsaved] from "sort(runs, &cfg)" to "limit": ')
    eq(ask_v(code, { 3, 12 }, { 1, 12 }), '[No Name]:1:13-3:13 [unsaved] from "sort(runs, &cfg)" to "limit": ')
    eq(ask_v(code, { 1, 0 }, { 2, 3 }), '[No Name]:1:1-2:4 [unsaved] from "    total = sort(runs, &"… to "    ": ')
    -- Typed keys through an `x` mapping, as with the README keymap.
    vim.keymap.set('x', '<F9>', function() h.ask() end, { buffer = source })
    local function typed(lines, keys)
      reset_source(lines)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys .. '<F9>', true, false, true), 'xt', false)
      eq(vim.fn.mode(), 'n')
      return s.inputs[#s.inputs].opts.default
    end
    eq(typed({ 'foo(bar, baz) foo' }, '4lvl'), '[No Name]:1:5-6 [unsaved] "ba": ')
    eq(typed({ 'foo(bar, baz) foo' }, '$vb'), '[No Name]:1:15-17 [unsaved] "foo": ')
    eq(typed({ 'aé界🙂b', 'next' }, 'lvl$'), '[No Name]:1:2-12 [unsaved] "é界🙂b\\n": ')
    eq(typed({ 'one', 'two', 'three' }, 'lvjjo'), '[No Name]:1:2-3:2 [unsaved] from "ne" to "th": ')
    vim.keymap.del('x', '<F9>', { buffer = source })
    -- 'selection' "old" keeps the legacy locator.
    eq(ask_v({ 'alpha beta' }, { 1, 0 }, { 1, 4 }, { selection = 'old' }), '[No Name]:1 at "alpha": ')
  end)
  test('ask charwise v escapes and bounds snippets without breaking UTF-8', function()
    local h, s = fresh('omp')
    -- quote, backslash, TAB, CR, ESC, DEL, C1 NEL, U+2028, U+2029, é, invalid byte, truncated sequence
    local nasty = 'q"\\\t\r\27\127\194\133\226\128\168\226\128\169é\255\226\128'
    local esc = [[q\"\\\t\r\x1b\x7f\u0085\u2028\u2029é\xff\xe2\x80]]
    local line = nasty .. string.rep('x', 60) .. nasty
    reset_source({ line })
    normal('v'); vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
    h.ask()
    local prompt = s.inputs[1].opts.default
    -- 14 characters at each end (a truncated sequence is two invalid bytes).
    eq(prompt, '[No Name]:1:1-' .. #line .. ' [unsaved] "' .. esc .. string.rep('x', 10) .. '"…"'
      .. string.rep('x', 10) .. esc .. '": ')
    assert(not prompt:find('[%z\1-\31\127]'), 'raw control byte in prompt')
    -- Overlong, surrogate and beyond-U+10FFFF encodings are invalid bytes, not characters.
    reset_source({ '\224\128\128|\237\160\128|\244\144\128\128|\240\159\153\130' })
    normal('v$')
    h.ask()
    eq(s.inputs[#s.inputs].opts.default,
      [[[No Name]:1:1-17 [unsaved] "\xe0\x80\x80|\xed\xa0\x80|\xf4\x90\x80\x80|🙂": ]])
    reset_source({ 'say "hi"\\n', 'x' })
    normal('v'); vim.api.nvim_win_set_cursor(0, { 1, 9 }); normal('$')
    h.ask(); eq(s.inputs[#s.inputs].opts.default, [[[No Name]:1:1-11 [unsaved] "say \"hi\"\\n\n": ]])
    -- Huge lines: exact coordinates, bounded hint, bounded reads, one single-line getregionpos().
    local read, get_text, get_lines = 0, vim.api.nvim_buf_get_text, vim.api.nvim_buf_get_lines
    local getregionpos, regions = vim.fn.getregionpos, {}
    local ok, err = pcall(function()
      reset_source({ string.rep('a', 200000), string.rep('é', 100000), string.rep('b', 200000) })
      vim.fn.getregionpos = function(p1, p2, opts)
        regions[#regions + 1] = { p1[2], p2[2] }
        return getregionpos(p1, p2, opts)
      end
      vim.api.nvim_buf_get_text = function(...)
        local chunk = get_text(...)
        for _, l in ipairs(chunk) do read = read + #l end
        return chunk
      end
      vim.api.nvim_buf_get_lines = function() error('charwise pointer must not read whole lines') end
      vim.api.nvim_win_set_cursor(0, { 1, 99 }); normal('v'); vim.api.nvim_win_set_cursor(0, { 3, 198999 })
      local started = vim.uv.hrtime()
      h.ask()
      print(string.format('PROFILE charwise ask 500KB selection elapsed_ms=%.3f read_bytes=%d',
        (vim.uv.hrtime() - started) / 1e6, read))
      eq(s.inputs[#s.inputs].opts.default, '[No Name]:1:100-3:199000 [unsaved] from "' .. string.rep('a', 24) .. '"… to …"'
        .. string.rep('b', 24) .. '": ')
      eq(regions, { { 3, 3 } })
      vim.api.nvim_win_set_cursor(0, { 2, 2 }); normal('v'); vim.api.nvim_win_set_cursor(0, { 2, 199996 })
      h.ask()
      eq(s.inputs[#s.inputs].opts.default, '[No Name]:2:3-199998 [unsaved] "' .. string.rep('é', 24) .. '"…"'
        .. string.rep('é', 24) .. '": ')
      eq(regions, { { 3, 3 }, { 2, 2 } })
    end)
    vim.api.nvim_buf_get_text, vim.api.nvim_buf_get_lines, vim.fn.getregionpos = get_text, get_lines, getregionpos
    assert(ok, err)
    assert(read <= 600, 'read too many bytes: ' .. read)
  end)
  test('ask charwise v: virtualedit all keeps the legacy pointer; path controls are escaped', function()
    local h, s = fresh('omp')
    local ve = { 'all', '' } -- global, window-local ('' inherits the global value)
    local function ask_v(lines, a, b, keys)
      reset_source(lines) -- resets 'virtualedit'
      vim.go.virtualedit = ve[1]
      vim.api.nvim_set_option_value('virtualedit', ve[2], { scope = 'local' })
      vim.api.nvim_win_set_cursor(0, a); normal('v'); vim.api.nvim_win_set_cursor(0, b)
      if keys then normal(keys) end
      h.ask()
      eq(vim.fn.mode(), 'n')
      return s.inputs[#s.inputs].opts.default
    end
    local global_ve = vim.go.virtualedit
    local original_cwd, original_name = vim.uv.cwd(), vim.api.nvim_buf_get_name(source)
    local ok, err = pcall(function()
      local function exact(p) return p:match('^%[No Name%]:%d+:%d+%-') ~= nil end
      eq(ask_v({ 'alpha beta' }, { 1, 0 }, { 1, 4 }), '[No Name]:1 at "alpha": ')
      eq(exact(ask_v({ 'a\tb', 'cd' }, { 1, 0 }, { 1, 1 })), false) -- inside the tab
      eq(exact(ask_v({ 'ab', 'cd' }, { 1, 0 }, { 1, 0 }, '$')), false) -- end of line
      ve = { '', 'block,all' }
      eq(exact(ask_v({ 'a\tb', 'cd' }, { 1, 0 }, { 1, 1 })), false)
      ve = { 'all', 'onemore' } -- the local value wins
      eq(ask_v({ 'alpha beta' }, { 1, 0 }, { 1, 4 }), '[No Name]:1:1-5 [unsaved] "alpha": ')
      -- Control characters in the buffer path stay on one escaped line; legacy paths are unchanged.
      reset_source({ 'alpha beta' })
      vim.api.nvim_buf_set_name(source, script_dir .. '/x\ty\nw\rz\27\194\133\226\128\168é.lua')
      vim.api.nvim_set_current_dir(script_dir)
      normal('v'); vim.api.nvim_win_set_cursor(0, { 1, 4 })
      h.ask()
      local prompt = s.inputs[#s.inputs].opts.default
      eq(prompt, [[x\ty\nw\rz\x1b\u0085\u2028é.lua:1:1-5 [unsaved] "alpha": ]])
      assert(not prompt:find('[%z\1-\31\127]'), 'raw control byte in prompt')
      eq(h.range_ref(1, 1), 'x\ty\nw\rz\27\194\133\226\128\168é.lua:1')
    end)
    vim.go.virtualedit = global_ve
    vim.api.nvim_set_option_value('virtualedit', '', { scope = 'local' })
    vim.api.nvim_set_current_dir(original_cwd)
    vim.api.nvim_buf_set_name(source, original_name)
    assert(ok, err)
  end)
  -- Select (a..b) charwise in `lines` with `filetype` and return the ask() prompt.
  local function ask_ft(h, s, filetype, lines, a, b, keys)
    reset_source(lines)
    vim.bo[source].filetype = filetype
    vim.bo[source].modified = false
    vim.api.nvim_win_set_cursor(0, a); normal('v'); vim.api.nvim_win_set_cursor(0, b)
    if keys then normal(keys) end
    h.ask()
    return s.inputs[#s.inputs].opts.default
  end
  local function fn_name(prompt)
    return prompt:match(' %(in (.-)%): $')
  end
  test('ask charwise v Tree-sitter names (actual Python/C++ parsers when installed)', function()
    local h, s = fresh('omp')
    local ok, err = pcall(function()
      if vim.treesitter.language.add('python') then
        local py = {
          'class A:', -- 1
          '    @staticmethod', -- 2
          '    def m(x):', -- 3
          '        def inner(y):', -- 4
          '            return y', -- 5
          '        return inner(x)', -- 6
          '', -- 7
          'async def g():', -- 8
          '    f = lambda z: z', -- 9
          '    return f', -- 10
        }
        eq(ask_ft(h, s, 'python', py, { 5, 12 }, { 5, 19 }), '[No Name]:5:13-20 "return y" (in inner): ')
        eq(fn_name(ask_ft(h, s, 'python', py, { 6, 22 }, { 4, 12 })), nil) -- outer/inner boundary, backward
        eq(fn_name(ask_ft(h, s, 'python', py, { 6, 8 }, { 6, 22 })), 'm')
        eq(fn_name(ask_ft(h, s, 'python', py, { 3, 4 }, { 6, 22 })), 'm') -- whole definition
        eq(fn_name(ask_ft(h, s, 'python', py, { 9, 8 }, { 9, 18 })), 'g') -- lambda: enclosing named function
        eq(fn_name(ask_ft(h, s, 'python', py, { 6, 8 }, { 8, 4 })), nil) -- cross-function
        eq(fn_name(ask_ft(h, s, 'python', py, { 6, 8 }, { 6, 8 }, '$')), nil) -- line break after the body
        eq(fn_name(ask_ft(h, s, 'python', py, { 2, 4 }, { 3, 10 })), nil) -- decorator outside function node
        eq(fn_name(ask_ft(h, s, 'python', py, { 1, 0 }, { 1, 4 })), nil) -- class scope
        eq(fn_name(ask_ft(h, s, 'python', { 'def f(:', '    return 1' }, { 2, 4 }, { 2, 9 })), nil) -- malformed
        local exact = ask_ft(h, s, 'python', py, { 4, 12 }, { 6, 22 })
        eq(exact, '[No Name]:4:13-6:23 from "inner(y):" to "return inner(x)": ')
        local siblings = { 'def outer():', '    def a():', '        return 1', '    def b():', '        return 2' }
        eq(fn_name(ask_ft(h, s, 'python', siblings, { 3, 8 }, { 5, 15 })), nil) -- nested siblings
        eq(fn_name(ask_ft(h, s, 'python', siblings, { 3, 8 }, { 3, 15 })), 'a')
        eq(fn_name(ask_ft(h, s, 'python', siblings, { 2, 4 }, { 4, 7 })), nil) -- outer start, inner end
      else
        print('SKIP Python parser unavailable')
      end
      if vim.treesitter.language.add('cpp') then
        local cpp = {
          'namespace ns {', -- 1
          'template <typename T>', -- 2
          'struct Foo {', -- 3
          '  Foo(int x) : v(x) {}', -- 4
          '  ~Foo() {}', -- 5
          '  int get() const { return v; }', -- 6
          '  operator bool() const { return true; }', -- 7
          '  int v;', -- 8
          '};', -- 9
          'template <typename T>', -- 10
          'Foo<T>::Foo(int x) : v(x) {}', -- 11
          'int *ptr(int a) { return nullptr; }', -- 12
          'int &ref(int a) { static int z; return z; }', -- 13
          'auto outer(int a) -> int {', -- 14
          '  auto f = [&](int b) { return a + b; };', -- 15
          '  return f(a);', -- 16
          '}', -- 17
          'bool Foo<int>::operator==(const Foo &o) const { return true; }', -- 18
          'TEST(Suite, Name) { int q = 1; }', -- 19
          'Foo::Bar(int x) { int r = x; }', -- 20
          '}', -- 21
        }
        local cases = {
          { { 4, 15 }, { 4, 18 }, 'Foo' }, -- in-class constructor
          { { 5, 2 }, { 5, 10 }, '~Foo' },
          { { 6, 20 }, { 6, 28 }, 'get' },
          { { 7, 26 }, { 7, 37 }, nil }, -- conversion operator: omitted
          { { 11, 22 }, { 11, 27 }, 'Foo<T>::Foo' }, -- scoped template constructor
          { { 12, 18 }, { 12, 32 }, 'ptr' },
          { { 13, 30 }, { 13, 40 }, 'ref' },
          { { 15, 24 }, { 15, 32 }, 'outer' }, -- lambda body: enclosing named function
          { { 15, 0 }, { 16, 5 }, 'outer' },
          { { 18, 50 }, { 18, 60 }, 'Foo<int>::operator==' },
          { { 19, 22 }, { 19, 26 }, nil }, -- macro-shaped definition without return type
          { { 20, 20 }, { 20, 26 }, nil }, -- scoped, no return type, not a constructor
          { { 12, 20 }, { 13, 10 }, nil }, -- cross-function
          { { 9, 0 }, { 9, 1 }, nil }, -- class scope
        }
        for _, case in ipairs(cases) do
          eq(fn_name(ask_ft(h, s, 'cpp', cpp, case[1], case[2])), case[3], vim.inspect(case))
        end
        eq(ask_ft(h, s, 'cpp', cpp, { 6, 20 }, { 6, 28 }), '[No Name]:6:21-29 "return v;" (in get): ')
        eq(fn_name(ask_ft(h, s, 'cpp', { 'int f() {', '  int x = (;', '  return x;', '}' }, { 3, 2 }, { 3, 9 })), nil)
        -- MISSING ';' inside the function (no ERROR ancestor): still malformed, omitted.
        eq(fn_name(ask_ft(h, s, 'cpp', { 'int f() {', '  int x = 1', '  return x;', '}' }, { 3, 2 }, { 3, 9 })), nil)
        eq(fn_name(ask_ft(h, s, 'cpp', { 'int f() {', '  int x = 1;', '  return x;', '}' }, { 3, 2 }, { 3, 9 })), 'f')
        local nested = { 'struct S {', '  int a() { return 1; }', '  int b() { return 2; }', '};',
          'int g() {', '  struct L { int h() { return 3; } };', '  return 0;', '}' }
        eq(fn_name(ask_ft(h, s, 'cpp', nested, { 2, 13 }, { 3, 13 })), nil) -- sibling methods
        eq(fn_name(ask_ft(h, s, 'cpp', nested, { 6, 30 }, { 7, 9 })), nil) -- inner start, outer end
        eq(fn_name(ask_ft(h, s, 'cpp', nested, { 7, 2 }, { 7, 9 })), 'g')
      else
        print('SKIP C++ parser unavailable')
      end
    end)
    vim.bo[source].filetype = ''
    assert(ok, err)
  end)
  test('ask charwise v Tree-sitter omission: other filetypes, missing/broken parser, large buffer', function()
    local h, s = fresh('omp')
    local get_parser, calls = vim.treesitter.get_parser, 0
    local ok, err = pcall(function()
      vim.treesitter.get_parser = function(...)
        calls = calls + 1
        return get_parser(...)
      end
      -- LaTeX/plaintext: exact coordinates and anchors, no macro semantics or parser use.
      eq(ask_ft(h, s, 'tex', { '\\section{Intro} \\emph{x}' }, { 1, 16 }, { 1, 23 }),
        '[No Name]:1:17-24 "\\\\emph{x}": ')
      eq(ask_ft(h, s, 'text', { 'def f():', '    return 1' }, { 2, 4 }, { 2, 11 }), '[No Name]:2:5-12 "return 1": ')
      eq(calls, 0)
      -- Large Python buffer: skipped before creating or running a parser.
      local big = {}
      for i = 1, 8000 do big[i] = 'def f' .. i .. '():\n    return 1' end
      big = vim.split(table.concat(big, '\n'), '\n')
      local started = vim.uv.hrtime()
      eq(ask_ft(h, s, 'python', big, { 2, 4 }, { 2, 11 }), '[No Name]:2:5-12 "return 1": ')
      print(string.format('PROFILE charwise ask large python elapsed_ms=%.3f', (vim.uv.hrtime() - started) / 1e6))
      eq(calls, 0)
      -- Missing or failing parser: the pointer is unchanged, without a name.
      vim.treesitter.get_parser = function() calls = calls + 1; return nil, 'no parser' end
      eq(ask_ft(h, s, 'python', { 'def f():', '    return 1' }, { 2, 4 }, { 2, 11 }), '[No Name]:2:5-12 "return 1": ')
      vim.treesitter.get_parser = function() calls = calls + 1; error('broken parser') end
      eq(ask_ft(h, s, 'cpp', { 'int f() {', '  return 1;', '}' }, { 2, 2 }, { 2, 10 }), '[No Name]:2:3-11 "return 1;": ')
      eq(calls, 2)
      -- Normal, linewise and blockwise pointers stay unchanged in a supported filetype.
      vim.treesitter.get_parser = get_parser
      reset_source({ 'def f():', '    return 1' }, 2, 4)
      vim.bo[source].filetype = 'python'
      h.ask(); eq(s.inputs[#s.inputs].opts.default, '[No Name]:2 at "return": ')
      normal('V'); h.ask(); eq(s.inputs[#s.inputs].opts.default, '[No Name]:2: ')
      normal('\22'); vim.api.nvim_win_set_cursor(0, { 2, 9 }); h.ask()
      eq(s.inputs[#s.inputs].opts.default, '[No Name]:2 at "return": ')
      h.ask(2, 2); eq(s.inputs[#s.inputs].opts.default, '[No Name]:2 at "return": ') -- explicit range: legacy
    end)
    vim.treesitter.get_parser = get_parser
    vim.bo[source].filetype = ''
    assert(ok, err)
  end)
  test('ask charwise v keeps the cwd-relative path of the receiving terminal', function()
    local h, s = fresh('omp')
    local original_cwd, original_name = vim.uv.cwd(), vim.api.nvim_buf_get_name(source)
    h.switch('omp')
    reset_source({ 'alpha beta' })
    vim.api.nvim_buf_set_name(source, script_dir .. '/fuzz_reference_only.lua')
    vim.api.nvim_set_current_dir(script_dir)
    local ok, err = pcall(function()
      normal('v'); vim.api.nvim_win_set_cursor(0, { 1, 4 })
      h.ask()
      local ref = h.range_ref(1, 1):gsub(':1$', '')
      eq(s.inputs[1].opts.default, ref .. ':1:1-5 [unsaved] "alpha": ')
    end)
    vim.api.nvim_set_current_dir(original_cwd)
    vim.api.nvim_buf_set_name(source, original_name)
    assert(ok, err)
  end)
  test('parse_model_items schemas and malformed/partial JSON fuzz', function()
    local h = fresh()
    local fixtures = { '', '{', 'null', 'false', '0', '"str"', '[]', '{}', '{"models":null}',
      '{"command":{"data":{"models":[null,1,false,{}, {"provider":"p","id":"m"}]}}}',
      '{"models":{"0":{"id":"m"}}}', '{"models":[{"provider":"p","id":"m","thinking":[null,0,false,"high"]}]}',
      '{"models":[{"id":"gpt-xhigh-effort"}]}', '{"models":[{"id":"claude-high"}]}',
      '{"models":[{"id":"unknown-low"}]}' }
    for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex', 'claude', 'unknown' }) do
      for _, json in ipairs(fixtures) do
        local items, valid = h.parse_model_items(name, json)
        assert(type(items) == 'table' and type(valid) == 'boolean')
        for _, item in ipairs(items) do assert(type(item.cmd) == 'string' and type(item.text) == 'string') end
      end
    end
    local values = { vim.NIL, false, true, 0, '', {}, { 'high', false, vim.NIL }, { bad = 'map' } }
    for i = 1, iterations do
      local name = i % 2 == 0 and 'omp' or 'agy'
      local m = {}
      for _, key in ipairs({ 'provider', 'id', 'selector', 'name', 'label', 'thinking' }) do m[key] = values[math.random(#values)] end
      local data = { models = { m, false, vim.NIL, 42 } }
      if i % 3 == 0 then data = { command = { data = data } } end
      local json = vim.json.encode(data)
      local items, valid = h.parse_model_items(name, json)
      eq(valid, true)
      for _, item in ipairs(items) do assert(type(item.cmd) == 'string') end
      h.parse_model_items(name, json:sub(1, math.random(0, #json)))
      h.parse_model_items(name, random_line())
    end
    local omp = h.parse_model_items('omp', catalog('omp')); eq(omp[2].cmd, '/switch provider/model:high')
    local agy = h.parse_model_items('agy', catalog('agy')); eq(agy[1].provider, 'google'); eq(agy[1].effort, 'high')
  end)
  test('async single-flight/cache/revalidate/empty/spawn failure', function()
    local h, s = fresh('omp')
    h.pick_model(); h.pick_model(); eq(#s.systems, 1)
    complete(s, 1, catalog('omp')); eq(#s.selects, 2)
    h.pick_model(); eq(#s.selects, 3); eq(#s.systems, 2)
    complete(s, 2, catalog('omp', 'new'))
    h.pick_model(); eq(s.selects[4].items[1].id, 'new')
    complete(s, 3, '{"models":[]}')
    h.pick_model(); eq(#s.systems, 4); eq(#s.selects, 4)
    complete(s, 4, '', 1, 'failed CLI'); assert(s.notices[#s.notices].msg:find('failed CLI', 1, true))
    s.spawn_error = true; h.pick_model(); assert(s.notices[#s.notices].msg:find('spawn failure', 1, true))
  end)
  test('async old harness callback keeps captured terminal target', function()
    local h, s = fresh('omp')
    h.ask(); local cb = s.inputs[1].cb
    h.setup({ default = 'agy', preload_models = false })
    cb('old prompt'); eq(s.sends[1].chan, channels.omp)
    h.setup({ default = 'omp', preload_models = false }); h.pick_model()
    h.setup({ default = 'codex', preload_models = false }); complete(s, 1, catalog('omp'))
    s.selects[1].cb(s.selects[1].items[1]); eq(s.sends[2].chan, channels.omp)
  end)
  test('BUG references must resolve in pinned receiving terminal cwd', function()
    local h, s = fresh('omp')
    local original_cwd = vim.uv.cwd()
    local original_name = vim.api.nvim_buf_get_name(source)
    h.switch('omp')
    local pinned = s.get_calls[#s.get_calls].opts.cwd
    reset_source()
    local filename = script_dir .. '/fuzz_reference_only.lua'
    vim.api.nvim_buf_set_name(source, filename)
    vim.api.nvim_set_current_dir(script_dir)
    h.ask(); h.prompt_range(1)
    local ref = h.range_ref(1, 1):gsub(':1$', '')
    local resolved = ref:sub(1, 1) == '/' and ref or vim.fs.normalize(pinned .. '/' .. ref)
    local diagnostics = { ask = s.inputs[1].opts.default, excerpt = body(s), resolved = resolved }
    vim.api.nvim_set_current_dir(original_cwd)
    vim.api.nvim_buf_set_name(source, original_name)
    eq(resolved, filename, vim.inspect(diagnostics))
  end)
  test('BUG partial-token and normal word locators must not collide', function()
    local h, s = fresh('omp')
    reset_source({ 'foo foobar foo' }, 1, 11)
    h.ask(); local final_word = s.inputs[1].opts.default
    vim.api.nvim_win_set_cursor(0, { 1, 4 }); normal('v')
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    h.ask(); local partial_word = s.inputs[2].opts.default
    assert(final_word ~= partial_word, 'distinct targets both resolve to ' .. final_word)
  end)
  test('model command sends slash command and deferred CR', function()
    local h, s = fresh('omp')
    h.pick_model(); complete(s, 1, catalog('omp'))
    s.selects[1].cb(s.selects[1].items[1])
    local submitted = body(s)
    drain(s.deferred)
    assert(submitted:sub(1, 8) == '/switch ',
      'expected /switch command, got: ' .. vim.inspect(submitted))
    eq(s.sends[#s.sends].bytes, '\r')
  end)
  test('P3 failed background catalog refresh has no diagnostic', function()
    local h, s = fresh('omp')
    h.pick_model(); complete(s, 1, catalog('omp'))
    h.pick_model(); local before = #s.notices
    complete(s, 2, '', 1, 'authentication expired')
    assert(#s.notices > before, 'failed refresh with warm cache emits no diagnostic')
  end)
  test('BUG failed agy effort send must not advance local effort state', function()
    local h, s = fresh('agy')
    s.send_error = true; h.cycle_thinking()
    h.pick_thinking(); s.selects[#s.selects].cb(s.selects[#s.selects].items[1])
    s.send_error = nil; h.cycle_thinking(); eq(body(s), '/effort xhigh')
  end)
  test('BUG interleaved prompt_range must not be submitted by earlier ask timer', function()
    local h, s = fresh('omp')
    h.ask(); s.inputs[1].cb('first prompt')
    h.prompt_range(1)
    drain(s.deferred)
    -- Composer now contains first prompt + excerpt; CR submits both unexpectedly.
    assert(not (#s.sends == 3 and s.sends[3].bytes == '\r'), 'ask CR submits subsequent no-submit excerpt')
  end)
  test('private focus_term paths reopen hidden windows', function()
    for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex', 'claude' }) do
      local h, s = fresh(name)
      local focus = up(h.pick_model, 'focus_term')
      local definitions = up(h.switch, 'harnesses')
      focus(definitions[name]) -- absent lookup is harmless
      h.switch(name); s.terms[name]:hide()
      vim.api.nvim_set_current_win(source_win)
      focus(definitions[name])
      eq(s.terms[name]:valid(), true)
      eq(vim.api.nvim_get_current_win(), s.terms[name].win)
    end
  end)
  test('randomized switch/toggle/setup/ask/paste state machine', function()
    local h, s = fresh('omp')
    local names = { 'omp', 'agy', 'opencode', 'codex', 'claude' }
    local selected, visible = 'omp', {}
    for i = 1, iterations do
      local name, action = names[math.random(#names)], math.random(5)
      if action == 1 then
        h.switch(name); selected = name
        for _, n in ipairs(names) do visible[n] = n == name end
      elseif action == 2 then
        h.toggle()
        for _, n in ipairs(names) do if n ~= selected then visible[n] = false end end
        visible[selected] = not visible[selected]
      elseif action == 3 then
        h.setup({ default = name, preload_models = false }); selected = name
      else
        reset_source({ 'state machine alpha', 'second' })
        local before = #s.sends
        if action == 4 then
          h.ask(); s.inputs[#s.inputs].cb('state ' .. i); drain(s.deferred)
          eq(#s.sends, before + 2)
        else
          h.prompt_range(1, 2); eq(#s.sends, before + 1)
        end
        eq(s.sends[before + 1].chan, channels[selected])
      end
      eq(h.current(), selected)
      for _, n in ipairs(names) do eq(s.terms[n] and s.terms[n]:valid() or false, visible[n] or false) end
    end
  end)
  test('deferred submit does not send to a dead captured channel', function()
    local h, s = fresh('omp')
    h.switch('omp')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local chan = vim.fn.jobstart({ '/bin/cat' }, { term = true })
    s.terms.omp.buf = buf
    reset_source()
    h.ask(); s.inputs[1].cb('captured channel')
    eq(s.sends[1].chan, chan)
    vim.fn.jobstop(chan)
    vim.fn.jobwait({ chan }, 1000)
    drain(s.deferred); eq(#s.sends, 1)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  test('BUG deferred CR send failure must be diagnosed', function()
    local h, s = fresh('omp')
    h.ask(); s.inputs[1].cb('prompt')
    local before = #s.notices
    s.send_error = true
    drain(s.deferred)
    assert(#s.notices > before, 'deferred CR error silently swallowed')
  end)
  test('terminal fallback ambiguity rejects duplicate live instances', function()
    local h, s = fresh('omp')
    local duplicate = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(duplicate)
    local chan = vim.fn.jobstart({ '/bin/cat' }, { term = true })
    vim.b[duplicate].snacks_terminal = { cmd = { 'omp' } }
    reset_source()
    local ok, err = pcall(function()
      h.prompt_range(1); eq(#s.sends, 0)
      assert(s.notices[#s.notices].msg:find('ambiguous', 1, true))
    end)
    vim.fn.jobstop(chan); vim.api.nvim_buf_delete(duplicate, { force = true })
    assert(ok, err)
  end)
  test('cwd pinned across switch and buffer/window deletion edges', function()
    local h, s = fresh('codex')
    local cwd = vim.uv.cwd()
    h.switch('codex'); local pinned = s.get_calls[#s.get_calls].opts.cwd
    vim.api.nvim_set_current_dir(script_dir)
    h.toggle(); h.toggle(); eq(s.get_calls[#s.get_calls].opts.cwd, pinned)
    vim.api.nvim_set_current_dir(cwd)
    local t = s.terms.codex
    vim.api.nvim_win_close(t.win, true)
    h.pick_model(); eq(t:valid(), true)
    local invalid = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(invalid, { force = true }); t.buf = invalid
    h.prompt_range(1); eq(s.sends[#s.sends].chan, channels.codex)
  end)
  test('PTY smoke: actual chan_send delivers markers to the selected terminal job', function()
    for _, name in ipairs({ 'omp', 'claude' }) do
      local h, s = fresh(name)
      local marker = 'HARNESS_PTY_SMOKE_' .. name
      s.real_send = true
      h.ask(); s.inputs[1].cb(marker)
      drain(s.deferred)
      local seen = vim.wait(2000, function()
        return table.concat(vim.api.nvim_buf_get_lines(buffers[name], 0, -1, false), ''):find(marker, 1, true) ~= nil
      end, 10)
      assert(seen, 'real PTY did not show marker: ' .. vim.inspect(vim.api.nvim_buf_get_lines(buffers[name], 0, -1, false)))
      drain(s.deferred)
    end
  end)
  test('bounded line_locator profiling on actual implementation', function()
    local h = fresh('omp'); local locator = up(h.ask, 'line_locator')
    for _, n in ipairs({ 100, 1000, 10000, 100000 }) do
      local line = string.rep('a ', math.floor(n / 2))
      local started = vim.uv.hrtime()
      for _ = 1, 3 do locator(line, 1) end
      print(string.format('PROFILE bytes=%d calls=3 elapsed_ms=%.3f', #line, (vim.uv.hrtime() - started) / 1e6))
    end
  end)
end
-- Restore globals before stopping real jobs and leaving the process.
vim.system, vim.schedule, vim.defer_fn = original.system, original.schedule, original.defer
vim.notify, vim.ui.input, vim.ui.select = original.notify, original.input, original.select
vim.api.nvim_chan_send, vim.fn.executable = original.send, original.executable
for _, chan in pairs(channels) do pcall(vim.fn.jobstop, chan) end
if vim.env.FUZZ_RESULTS then
  local summary = { seed = seed, iterations = iterations, counts = counts, results = results, nvim = vim.version() }
  vim.fn.writefile({ vim.json.encode(summary) }, vim.env.FUZZ_RESULTS)
end
print(string.format('SUMMARY pass=%d fail=%d seed=%d', counts.pass, counts.fail, seed))
vim.cmd(counts.fail == 0 and 'qa!' or 'cquit 1')
