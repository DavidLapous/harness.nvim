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
for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex' }) do
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
  for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex' }) do
    test(name .. ': setup/switch/hide/toggle/current/focus', function()
      local h, s = fresh(name)
      eq(h.current(), name)
      h.switch(name)
      eq(s.terms[name]:valid(), true)
      eq(vim.api.nvim_get_current_win(), s.terms[name].win)
      h.toggle(); eq(s.terms[name]:valid(), false)
      h.toggle(); eq(s.terms[name]:valid(), true)
      for _, next_name in ipairs({ 'codex', 'omp', 'agy', 'opencode', name }) do
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
        eq(body(s), name == 'codex' and '/model' or '/models')
        eq(s.terms[name]:valid(), true)
        eq(vim.api.nvim_get_current_win(), s.terms[name].win)
      end
      drain(s.deferred)
      h.cycle_thinking()
      eq(body(s), ({ omp = '\27[Z', agy = '/effort xhigh', opencode = '\20', codex = '/model' })[name])
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
      elseif name == 'codex' then
        eq(body(s), '/model')
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
    h.toggle(); eq(#s.selects[1].items, 4); s.selects[1].cb(nil); eq(h.current(), nil)
    h.switch(); s.selects[2].cb(s.selects[2].items[4]); eq(h.current(), 'codex')
    h.setup({ preload_models = true }); eq(#s.systems, 2)
    h.setup({ preload_models = true }); eq(#s.systems, 2)
    local saved = package.loaded['snacks.terminal']
    package.loaded['snacks.terminal'] = nil
    package.preload['snacks.terminal'] = function() error('missing Snacks') end
    h.switch('omp'); eq(h.current(), 'codex')
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
        local expected = mode == 'V' and '[No Name]:1: ' or '[No Name]:1' .. oracle(line, col, selected, start) .. ': '
        eq(s.inputs[#s.inputs].opts.default, expected, 'visual fuzz ' .. i .. ' ' .. vim.inspect(line))
        eq(vim.fn.mode(), 'n')
      end
    end
    for _, mode in ipairs({ 'v', 'V', '\22' }) do
      for _, backward in ipairs({ false, true }) do
        reset_source({ 'alpha', 'beta', 'gamma' }, backward and 3 or 1)
        normal(mode); vim.api.nvim_win_set_cursor(0, { backward and 1 or 3, 0 })
        h.ask(); eq(s.inputs[#s.inputs].opts.default, '[No Name]:1-3: ')
      end
    end
  end)
  test('exclusive visual selection excludes right endpoint', function()
    local h, s = fresh('omp')
    reset_source({ 'alpha beta' })
    vim.o.selection = 'exclusive'
    normal('v'); vim.api.nvim_win_set_cursor(0, { 1, 5 })
    eq(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'v', exclusive = true })[1], 'alpha')
    h.ask(); eq(s.inputs[1].opts.default, '[No Name]:1 at "alpha": ')
  end)
  test('parse_model_items schemas and malformed/partial JSON fuzz', function()
    local h = fresh()
    local fixtures = { '', '{', 'null', 'false', '0', '"str"', '[]', '{}', '{"models":null}',
      '{"command":{"data":{"models":[null,1,false,{}, {"provider":"p","id":"m"}]}}}',
      '{"models":{"0":{"id":"m"}}}', '{"models":[{"provider":"p","id":"m","thinking":[null,0,false,"high"]}]}',
      '{"models":[{"id":"gpt-xhigh-effort"}]}', '{"models":[{"id":"claude-high"}]}',
      '{"models":[{"id":"unknown-low"}]}' }
    for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex', 'unknown' }) do
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
  test('all four private focus_term paths reopen hidden windows', function()
    for _, name in ipairs({ 'omp', 'agy', 'opencode', 'codex' }) do
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
    local names = { 'omp', 'agy', 'opencode', 'codex' }
    local selected, visible = 'omp', {}
    for i = 1, iterations do
      local name, action = names[math.random(4)], math.random(5)
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
  test('PTY smoke: actual chan_send delivers marker to terminal job', function()
    local h, s = fresh('omp')
    s.real_send = true
    h.ask(); s.inputs[1].cb('HARNESS_PTY_SMOKE_21102026')
    drain(s.deferred)
    local seen = vim.wait(2000, function()
      return table.concat(vim.api.nvim_buf_get_lines(buffers.omp, 0, -1, false), ''):find('HARNESS_PTY_SMOKE_21102026', 1, true) ~= nil
    end, 10)
    assert(seen, 'real PTY did not show marker: ' .. vim.inspect(vim.api.nvim_buf_get_lines(buffers.omp, 0, -1, false)))
    drain(s.deferred)
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
