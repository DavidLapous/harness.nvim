-- harness.nvim — Lightweight Neovim PTY bridge for terminal AI harnesses (omp, agy, opencode, codex).
--
-- Drives the active harness running inside Neovim's snacks.terminal
-- directly over its PTY channel using bracketed paste (\27[200~...\27[201~).

local uv = vim.uv or vim.loop

local M = {}

local current = nil
local harness_order = { "omp", "agy", "opencode", "codex" }
local harnesses = {
	omp = {
		name = "omp",
		cmd = "omp",
		label = "Oh My Pi",
		models_cmd = { "omp", "models", "--json" },
	},
	agy = {
		name = "agy",
		cmd = "agy",
		label = "Antigravity",
		models_cmd = { "agy", "--output-format", "json", "models" },
	},
	opencode = {
		name = "opencode",
		cmd = "opencode",
		label = "OpenCode",
		model_slash = "/models",
	},
	codex = {
		name = "codex",
		cmd = "codex",
		label = "Codex CLI",
		model_slash = "/model",
	},
}
local term_opts = { count = 1, win = { position = "right", width = 0.4 } }
local agy_efforts = { "minimal", "low", "medium", "high", "xhigh", "max" }
local agy_effort_idx = 4 -- default "high"
local model_cache = {}
local model_inflight = {}

local function agy_provider(id)
	if id:find("^gemini%-") then
		return "google"
	elseif id:find("^claude%-") then
		return "anthropic"
	elseif id:find("^gpt%-") then
		return "openai"
	end
	return "agy"
end

local function split_agy_effort(id)
	local stripped = id:gsub("%-effort$", "")
	for _, e in ipairs(agy_efforts) do
		local base = stripped:match("^(.+)%-" .. e .. "$")
		if base then
			return base, e
		end
	end
	return id, nil
end

local function parse_model_items(harness_name, stdout)
	local ok, decoded = pcall(vim.json.decode, stdout or "")
	if not ok or type(decoded) ~= "table" then
		return {}, false
	end
	local cmd_data = type(decoded.command) == "table" and decoded.command.data or nil
	local models = (type(cmd_data) == "table" and cmd_data.models) or decoded.models
	if type(models) ~= "table" then
		return {}, false
	end

	local items = {}
	local function add(provider, id, name, effort, cmd)
		local label = type(name) == "string" and name or id
		local text = effort and string.format("[%s] %s · %s reasoning  (%s)", provider, id, effort, label)
			or string.format("[%s] %s  (%s)", provider, id, label)
		items[#items + 1] = {
			provider = provider,
			id = id,
			name = label,
			effort = effort,
			cmd = cmd,
			text = text,
		}
	end

	for _, m in ipairs(models) do
		if type(m) == "table" then
			if harness_name == "omp" and type(m.provider) == "string" and type(m.id) == "string" then
				local selector = type(m.selector) == "string" and m.selector or (m.provider .. "/" .. m.id)
				local efforts = (type(m.thinking) == "table" and #m.thinking > 0) and m.thinking or nil
				if efforts then
					for _, e in ipairs(efforts) do
						if type(e) == "string" then
							add(m.provider, m.id, m.name, e, "/switch " .. selector .. ":" .. e)
						end
					end
				else
					add(m.provider, m.id, m.name, nil, "/switch " .. selector)
				end
			elseif harness_name == "agy" and type(m.id) == "string" then
				local base, effort = split_agy_effort(m.id)
				add(agy_provider(base), base, m.label, effort, "/model " .. m.id)
			end
		end
	end
	return items, true
end

local function notify_err(err, where, h_name)
	if err then
		vim.notify("[" .. (h_name or current or "ai") .. "] " .. where .. ": " .. err, vim.log.levels.ERROR)
		return true
	end
	return false
end

local function refresh_models(harness_name)
	local h = harnesses[harness_name]
	if not h or not h.models_cmd then
		return false, "no CLI model catalog for " .. tostring(harness_name)
	end
	if model_inflight[harness_name] then
		return true
	end
	model_inflight[harness_name] = {}
	local ok, sys_err = pcall(vim.system, h.models_cmd, { text = true, timeout = 10000 }, function(res)
		vim.schedule(function()
			local waiters = model_inflight[harness_name] or {}
			model_inflight[harness_name] = nil
			local items, valid = {}, false
			if res.code == 0 then
				items, valid = parse_model_items(harness_name, res.stdout)
			end
			if valid then
				model_cache[harness_name] = (#items > 0) and items or nil
			end
			local result = model_cache[harness_name] or {}
			if not valid or (#result == 0 and #waiters > 0) then
				local msg = vim.trim((res.stderr and res.stderr ~= "" and res.stderr) or res.stdout or "")
				notify_err(msg ~= "" and msg or "no models returned", "models", harness_name)
			end
			for _, cb in ipairs(waiters) do
				cb(result)
			end
		end)
	end)
	if not ok then
		model_inflight[harness_name] = nil
		return false, tostring(sys_err)
	end
	return true
end

local function fetch_model_items(harness_name, callback)
	if model_cache[harness_name] then
		callback(model_cache[harness_name])
		refresh_models(harness_name)
		return
	end
	if not model_inflight[harness_name] then
		vim.notify("[" .. harness_name .. "] fetching models...", vim.log.levels.INFO)
		local ok, err = refresh_models(harness_name)
		if not ok then
			notify_err(err, "models", harness_name)
			return callback({})
		end
	end
	table.insert(model_inflight[harness_name], callback)
end

M.parse_model_items = parse_model_items

local function chan_alive(chan)
	if not chan or chan <= 0 then
		return false
	end
	local ok, info = pcall(vim.api.nvim_get_chan_info, chan)
	return ok and type(info) == "table" and next(info) ~= nil and vim.fn.jobwait({ chan }, 0)[1] == -1
end

local function get_term_opts(create)
	term_opts.cwd = term_opts.cwd or uv.cwd()
	if create == false then
		return { create = false, count = term_opts.count, cwd = term_opts.cwd }
	end
	return term_opts
end

local function term_chan(h)
	local ok, st = pcall(require, "snacks.terminal")
	if ok then
		local t = st.get(h.cmd, get_term_opts(false))
		if t and t.buf and vim.api.nvim_buf_is_valid(t.buf) then
			local chan = vim.bo[t.buf].channel
			if chan_alive(chan) then
				return chan
			end
		end
	end
	local matches = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
			local meta = vim.b[buf].snacks_terminal
			local cmd = meta and (type(meta.cmd) == "table" and meta.cmd[1] or meta.cmd)
			if cmd == h.cmd then
				local chan = vim.bo[buf].channel
				if chan_alive(chan) then
					matches[#matches + 1] = chan
				end
			end
		end
	end
	if #matches == 1 then
		return matches[1]
	elseif #matches > 1 then
		return nil, "multiple running " .. h.cmd .. " terminals; ambiguous target"
	end
	return nil, "no running " .. h.cmd .. " terminal in this editor (toggle terminal to start " .. h.cmd .. ")"
end

local function send_raw(h, bytes, where)
	local chan, err = term_chan(h)
	if not chan then
		return notify_err(err, where, h.name)
	end
	local ok, send_err = pcall(vim.api.nvim_chan_send, chan, bytes)
	if not ok then
		return notify_err(tostring(send_err), where, h.name)
	end
	return false
end

local pending_cr = {}

local function flush_cr(chan)
	local p = pending_cr[chan]
	if not p then
		return
	end
	pending_cr[chan] = nil
	if chan_alive(chan) then
		local ok, err = pcall(vim.api.nvim_chan_send, chan, "\r")
		if not ok then
			notify_err(tostring(err), p.where, p.name)
		end
	end
end

-- shortcut: bracketed paste + deferred CR (30ms) over PTY, upgrade only if a harness drops bracketed-paste support
local function send_paste(h, text, submit, where)
	local chan, err = term_chan(h)
	if not chan then
		return notify_err(err, where, h.name)
	end
	flush_cr(chan)
	local clean = text
	while clean:find("\27%[20[01]~") do
		clean = clean:gsub("\27%[20[01]~", "")
	end
	local ok, send_err = pcall(vim.api.nvim_chan_send, chan, "\27[200~" .. clean .. "\27[201~")
	if not ok then
		return notify_err(tostring(send_err), where, h.name)
	end
	if submit then
		pending_cr[chan] = { name = h.name, where = where }
		vim.defer_fn(function()
			flush_cr(chan)
		end, 30)
	end
	return false
end

local function exit_visual()
	if vim.fn.mode():match("^[vV\x16]") then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "nx", false)
	end
end

local function hide_others(active_name, where)
	local ok, st = pcall(require, "snacks.terminal")
	if not ok then
		notify_err(tostring(st), where or "terminal", active_name or "ai")
		return nil
	end
	for _, name in ipairs(harness_order) do
		if name ~= active_name then
			local other = st.get(harnesses[name].cmd, get_term_opts(false))
			if other and other:valid() then
				other:hide()
			end
		end
	end
	return st
end

local function focus_term(h)
	local ok, st = pcall(require, "snacks.terminal")
	if not ok then
		return
	end
	local t = st.get(h.cmd, get_term_opts(false))
	if t then
		if not t:valid() then
			t:show()
		end
		if t.win and vim.api.nvim_win_is_valid(t.win) then
			vim.api.nvim_set_current_win(t.win)
			vim.cmd.startinsert()
		end
	end
end

function M.current()
	return current
end

function M.switch(name)
	if not name then
		exit_visual()
		if vim.fn.mode() == "t" then
			vim.cmd.stopinsert()
		end
		local items = {}
		for _, k in ipairs(harness_order) do
			local h = harnesses[k]
			local active = (k == current) and "  (current)" or ""
			items[#items + 1] = { name = k, text = string.format("%s — %s%s", k, h.label, active) }
		end
		vim.ui.select(items, {
			prompt = "Select AI harness:",
			format_item = function(item)
				return item.text
			end,
		}, function(choice)
			if choice then
				M.switch(choice.name)
			end
		end)
		return
	end
	local h = harnesses[name]
	if not h then
		return notify_err("unknown harness: " .. tostring(name), "switch", "ai")
	end
	local st = hide_others(name, "switch")
	if not st then
		return
	end
	current = name
	local target = st.get(h.cmd, get_term_opts())
	if target and not target:valid() then
		target:show()
	end
	if target and target.win and vim.api.nvim_win_is_valid(target.win) then
		vim.api.nvim_set_current_win(target.win)
	end
	if h.models_cmd then
		refresh_models(name)
	end
	vim.notify(string.format("[ai] harness → %s (%s)", name, h.label), vim.log.levels.INFO)
end

function M.toggle()
	if not current then
		return M.switch()
	end
	local st = hide_others(current, "toggle")
	if st then
		st.toggle(harnesses[current].cmd, get_term_opts())
	end
end

local function resolve_range(a, b)
	if a == nil then
		if vim.fn.mode():match("^[vV\x16]") then
			local v, cur = vim.fn.line("v"), vim.fn.line(".")
			a, b = math.min(v, cur), math.max(v, cur)
			exit_visual()
		else
			a = vim.api.nvim_win_get_cursor(0)[1]
		end
	end
	b = b or a
	if b < a then
		b = a
	end
	return a, b
end

--- Range description "path:start-end" (relative to cwd).
---@param a integer start line
---@param b integer end line
function M.range_ref(a, b)
	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		name = "[No Name]"
	else
		local base_cwd = get_term_opts(false).cwd
		name = (vim.fs.relpath and vim.fs.relpath(base_cwd, name)) or name
	end
	if a == b then
		return name .. ":" .. a
	end
	return name .. ":" .. a .. "-" .. b
end

local function ordinal(n)
	local r100 = n % 100
	if r100 >= 11 and r100 <= 13 then
		return n .. "th"
	end
	return n .. (({ [1] = "st", [2] = "nd", [3] = "rd" })[n % 10] or "th")
end

local function format_at(word, idx, total)
	if total > 1 and idx > 0 then
		return string.format(' at %s "%s"', ordinal(idx), word)
	end
	return string.format(' at "%s"', word)
end

local function line_locator(line, col, sel, sel_s)
	local pos = vim.str_utf_pos(line)
	local tokens, cur_tok = {}, nil
	local target_col = sel_s or col
	local ts, te
	for i, s in ipairs(pos) do
		local e = (pos[i + 1] or (#line + 1)) - 1
		local ch = line:sub(s, e)
		if #ch > 1 and vim.fn.strchars(" " .. ch, 1) == 1 then
			if ts then
				te = e
			end
		elseif vim.fn.charclass(ch) == 2 then
			ts = ts or s
			te = e
		elseif ts then
			local tok = { word = line:sub(ts, te), s = ts, e = te }
			tokens[#tokens + 1] = tok
			if ts <= target_col and target_col <= te then
				cur_tok = tok
			end
			ts = nil
		end
	end
	if ts then
		local tok = { word = line:sub(ts, te), s = ts, e = te }
		tokens[#tokens + 1] = tok
		if ts <= target_col and target_col <= te then
			cur_tok = tok
		end
	end

	if sel then
		if sel:match("^%s*$") then
			return ":" .. target_col
		end
		if cur_tok and sel_s + #sel - 1 <= cur_tok.e then
			if cur_tok.s ~= sel_s or cur_tok.word ~= sel or sel:match("^%d") then
				return ":" .. target_col
			end
			local total, idx = 0, 0
			for _, t in ipairs(tokens) do
				if t.word == sel then
					total = total + 1
					if t == cur_tok then
						idx = total
					end
				end
			end
			return format_at(sel, idx, total)
		end
		local total, idx, init = 0, 0, 1
		while init <= #line do
			local s = line:find(sel, init, true)
			if not s then
				break
			end
			total = total + 1
			if s == sel_s then
				idx = total
			end
			init = s + 1
		end
		if idx == 0 then
			return ":" .. target_col
		end
		return format_at(sel, idx, total)
	end

	if not cur_tok or cur_tok.word:match("^%d") then
		return ":" .. col
	end
	local total, idx = 0, 0
	for _, t in ipairs(tokens) do
		if t.word == cur_tok.word then
			total = total + 1
			if t == cur_tok then
				idx = total
			end
		end
	end
	return format_at(cur_tok.word, idx, total)
end

--- Collect a prompt in Neovim's input dialog and submit it to the active
--- harness with the cursor line or visual selection range as a read pointer.
---@param a integer? start line (default: visual selection or cursor line)
---@param b integer? end line
function M.ask(a, b)
	local mode = (a == nil) and vim.fn.mode() or ""
	local cur_pos = vim.api.nvim_win_get_cursor(0)
	local cur_line, col = cur_pos[1], cur_pos[2] + 1
	local sel, sel_s
	if (mode == "v" or mode == "\x16") and vim.fn.line("v") == vim.fn.line(".") then
		sel = (vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })[1]) or ""
		sel_s = math.min(vim.fn.col("v"), vim.fn.col("."))
	end
	a, b = resolve_range(a, b)
	local h = harnesses[current]
	if not h then
		return notify_err("no harness selected (press <C-.> or <leader>as to select one)", "ask", "ai")
	end
	local loc = ""
	if a == b and a == cur_line and mode ~= "V" then
		local line = vim.api.nvim_buf_get_lines(0, a - 1, a, false)[1] or ""
		loc = line_locator(line, col, sel, sel_s)
	end
	local prefix = M.range_ref(a, b) .. loc .. ": "
	vim.ui.input({ prompt = "[" .. h.name .. "] ", default = prefix }, function(text)
		if text == nil or text:match("^%s*$") then
			return
		end
		send_paste(h, text, true, "ask")
	end)
end

--- Paste the given line range into the active composer as a fenced excerpt.
---@param a integer? start line (default: visual selection or cursor line)
---@param b integer? end line
---@param where string? label for error notify
function M.prompt_range(a, b, where)
	a, b = resolve_range(a, b)
	local h = harnesses[current]
	if not h then
		return notify_err("no harness selected (press <C-.> or <leader>as to select one)", where or "operator", "ai")
	end
	local lines = vim.api.nvim_buf_get_lines(0, a - 1, b, false)
	local lang = vim.bo.filetype
	local fence = "```"
	local body = table.concat(lines, "\n")
	while body:find(fence, 1, true) do
		fence = fence .. "`"
	end
	local text = M.range_ref(a, b)
		.. "\n"
		.. fence
		.. lang
		.. "\n"
		.. body
		.. "\n"
		.. fence
		.. "\n\n"
	send_paste(h, text, false, where or "operator")
end

--- operatorfunc entry for `send_operator()` / `send_line()`.
function M.operator()
	M.prompt_range(vim.fn.line("'["), vim.fn.line("']"))
end

--- expr-mapping helper for operator range send (e.g. `go` in normal/visual mode).
function M.send_operator()
	vim.go.operatorfunc = "v:lua.require'harness'.operator"
	return "g@"
end

--- expr-mapping helper for current-line send (e.g. `goo` in normal mode).
function M.send_line()
	vim.go.operatorfunc = "v:lua.require'harness'.operator"
	return "g@_"
end

--- Pick `(provider, model, reasoning effort)` in Neovim (with subword search
--- via `snacks.picker`) or open the active harness's built-in TUI model dialog.
function M.pick_model()
	local h_name = current
	local h = harnesses[h_name]
	if not h then
		return notify_err("no harness selected (press <C-.> or <leader>as to select one)", "pick_model", "ai")
	end
	if h.model_slash then
		if not send_paste(h, h.model_slash, true, "pick_model") then
			focus_term(h)
		end
		return
	end
	fetch_model_items(h_name, function(items)
		if #items == 0 then
			return
		end
		vim.ui.select(items, {
			prompt = "Select " .. h.label .. " model (type subwords, e.g. 'sonnet hi' or 'gpt hig'):",
			format_item = function(item)
				return item.text
			end,
		}, function(choice)
			if not choice then
				return
			end
			if not send_paste(h, choice.cmd, true, "pick_model") then
				if h_name == "agy" and choice.effort then
					for i, e in ipairs(agy_efforts) do
						if e == choice.effort then
							agy_effort_idx = i
							break
						end
					end
				end
				local suffix = choice.effort and (" (" .. choice.effort .. ")") or ""
				vim.notify("[" .. h_name .. "] model → [" .. choice.provider .. "] " .. choice.id .. suffix, vim.log.levels.INFO)
			end
		end)
	end)
end

--- Cycle thinking/effort level in the active harness.
function M.cycle_thinking(direction)
	local h = harnesses[current]
	if not h then
		return notify_err("no harness selected (press <C-.> or <leader>as to select one)", "cycle_thinking", "ai")
	end
	if current == "omp" then
		send_raw(h, "\27[Z", "cycle_thinking")
		return
	elseif current == "opencode" then
		send_raw(h, "\20", "cycle_thinking")
		return
	elseif current == "codex" then
		if not send_paste(h, "/model", true, "cycle_thinking") then
			focus_term(h)
		end
		return
	end
	local step = (direction == "backward") and -1 or 1
	local next_idx = ((agy_effort_idx - 1 + step) % #agy_efforts) + 1
	local level = agy_efforts[next_idx]
	if not send_paste(h, "/effort " .. level, true, "cycle_thinking") then
		agy_effort_idx = next_idx
		vim.notify("[agy] effort → " .. level, vim.log.levels.INFO)
	end
end

---@param opts? { default?: "omp"|"agy"|"opencode"|"codex", win?: table, preload_models?: boolean }
function M.setup(opts)
	opts = opts or {}
	if opts.default and harnesses[opts.default] then
		current = opts.default
	end
	if opts.win then
		term_opts.win = vim.tbl_deep_extend("force", term_opts.win, opts.win)
	end
	if opts.preload_models ~= false then
		for name, h in pairs(harnesses) do
			if h.models_cmd and vim.fn.executable(h.cmd) == 1 then
				refresh_models(name)
			end
		end
	end
end

return M
