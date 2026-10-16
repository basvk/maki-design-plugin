-- ── Design mode plugin ──────────────────────────────────────────────────────
-- Turns maki into a UI/UX design helper on demand. `/design` toggles a persona
-- (owned prompt slots) plus a preview loop. Pixels come from the sibling
-- `browser` plugin: its `browser_screenshot` already returns vision images, so
-- this plugin never tries to relay images through `maki.agent.call_tool`
-- (which is text-only).

local DEFAULT_IDENTITY = [[You are Maki, an interactive CLI coding agent. Use the tools available to assist the user with software engineering tasks. Complete tasks successfully while minimizing token usage and tool calls to avoid context bloat.

You must NEVER generate or guess URLs unless they are for helping the user with programming.]]

local DESIGN_IDENTITY = [[You are Maki in design mode — a UI/UX design and frontend aesthetics specialist. You shape interfaces people actually want to use, and you care about how they look and feel as much as whether they work.

Prioritize visual hierarchy, spacing, type, color, motion, and accessibility over minimal diffs. Iterate on the real rendered output: screenshot it, look at it, critique it, and change it. The workflow is below.]]

local DEFAULT_TONE = [[- Be concise. Your output is displayed on a CLI rendered in monospace. Use GitHub-flavored markdown.
- Only use emojis if explicitly requested.
- Do not add comments to code unless asked.
- Output text to communicate with the user; all text you output outside of tool use is displayed to the user. Only use tools to complete tasks. NEVER use bash echo or other command-line tools to communicate thoughts, explanations, diagrams, or instructions to the user. Output all communication directly in your response text instead.
- NEVER create files unless absolutely necessary. ALWAYS prefer editing existing files.]]

local DESIGN_TONE = [[- Lead with the design decision and why, then the change. Be direct about what looks wrong.
- Critique the rendered result, not just the code: name the specific visual problem (contrast, alignment, crowding, inconsistent radii) before fixing it.
- No filler praise. If a result is good, say what makes it good in one line.
- When referencing code, use `file_path:line_number`. Reference screenshots by what they show, not by path.]]

-- The full workflow lives here, inlined, rather than in a separate skill file:
-- maki has no API to register a skill, and the bundled `skill` tool only scans
-- fixed directories. Gated on `active`, so it costs nothing when design mode is
-- off.
local DESIGN_CONVENTIONS = [[# Design mode

Aesthetics and usability are the goal here; correctness still matters but does not win arguments against the interface. Shape an interface people actually want to use — work on the real rendered output and let what you see drive the next change.

## Loop
1. **Understand the target.** What is this screen for, who uses it, what is the key action? Read the existing UI code and any design tokens/theme before touching anything.
2. **Preview it.** `design_preview` starts the dev server and returns a URL. For static HTML, pass `command = "python3 -m http.server 3000"` and `url = "http://localhost:3000"`.
3. **Look at it.** `browser_launch` at the URL, then `browser_screenshot`. These return images you can actually see. Check the viewport matrix from `design_viewports` — never judge a layout from one width.
4. **Critique, specifically.** Name the problem before fixing it: contrast, alignment, crowding, inconsistent radii/spacing, unclear hierarchy, weak affordance. Compare against the intent in step 1.
5. **Change one thing well.** Derive values from the design system. Write the change, reload, screenshot again.
6. **Verify.** Re-shoot the same viewport(s). State what improved and what is still off. Repeat until it holds up, then summarize.

## Reading a screenshot
- **Hierarchy** — does the eye land on the primary action first?
- **Spacing** — is it on a scale; are related things grouped?
- **Type** — consistent scale, line length, readable sizes and contrast.
- **Color** — tokens reused; contrast meets WCAG AA (4.5:1 body, 3:1 large/UI).
- **States** — hover, focus (visible), active, disabled, empty, loading, error.
- **Responsive** — no overflow, no clipping, no orphaned controls at 390px.
- **Motion** — purposeful; honors `prefers-reduced-motion`.

## Rules
- Prefer an established design system in the repo (tokens, theme, component library) over inventing values. Check for one before styling anything.
- No magic values: derive spacing/color/type from tokens or a scale, not eyeballed numbers.
- Keep keyboard focus visible and controls reachable; do not trade a11y for looks.
- Every visual change is verified by a browser screenshot at a real viewport before you claim it is done. "It compiles" is not a design result.
- Respect `prefers-reduced-motion` and color contrast (WCAG AA).

## Human feedback
The user may add notes with `/design-note <text>`. They land in `.maki/design/notes.md` and are read back by `design_viewports`. Treat them as authoritative taste calls and fold them into the next iteration.]]

-- Settings live in a plain table, not `register_options`: that call is keyed by
-- plugin name, and every module `require`d from `global/init.lua` shares the
-- `global` namespace, so `browser.lua` already claimed it. Call `setup` from
-- init.lua to override.
local config = {
  preview_port = 3000,
  preview_timeout = 20,
}

local M = {}

function M.setup(overrides)
  for k, v in pairs(overrides or {}) do
    config[k] = v
  end
end

local active = false

-- ── Prompt slots ────────────────────────────────────────────────────────────
-- Singletons (identity, tone) are owned while the plugin is loaded, so each
-- callback returns the built-in text when design mode is off. Toggling flips
-- what these return before the next run, and maki delivers the delta as a
-- context update; the prompt prefix itself is never rewritten.

maki.api.set_prompt({
  prompt = "system",
  slot = "identity",
  content = function() return active and DESIGN_IDENTITY or DEFAULT_IDENTITY end,
})

maki.api.set_prompt({
  prompt = "system",
  slot = "tone",
  content = function() return active and DESIGN_TONE or DEFAULT_TONE end,
})

maki.api.register_prompt_hint({
  prompt = "system",
  slot = "conventions",
  content = function()
    if not active then
      return nil
    end
    return DESIGN_CONVENTIONS
  end,
})

-- ── Dev server management (framework-agnostic) ──────────────────────────────

local VIEWPORTS = {
  mobile = { 390, 844 },
  tablet = { 834, 1112 },
  desktop = { 1440, 900 },
}

local VIEWPORT_ORDER = { "mobile", "tablet", "desktop" }

local preview = {
  job_id = nil,
  url = nil,
  cmd = nil,
  log = nil,
}

local function design_dir()
  local cwd = maki.uv.cwd() or "/tmp"
  return maki.fs.joinpath(cwd, ".maki", "design")
end

local function ensure_design_dir()
  local dir = design_dir()
  local _, err = maki.fs.mkdir(dir, { parents = true })
  if err then
    return nil, err
  end
  return dir
end

-- First script that looks like a dev server, so repos without a recognizable
-- framework still work.
local function detect_dev_command()
  local cwd = maki.uv.cwd()
  if not cwd then
    return nil
  end
  local pkg = maki.fs.read(maki.fs.joinpath(cwd, "package.json"))
  if not pkg then
    return nil
  end
  local data = maki.json.decode(pkg)
  if not data or not data.scripts then
    return nil
  end
  for _, name in ipairs({ "dev", "start", "serve" }) do
    if data.scripts[name] then
      return "npm run " .. name
    end
  end
  return nil
end

local function preview_alive()
  if not preview.job_id then
    return false
  end
  local info = maki.fn.jobinfo(preview.job_id)
  return info ~= nil and info.status == "running"
end

local function stop_preview()
  if preview.job_id then
    maki.fn.jobstop(preview.job_id)
  end
  preview.job_id = nil
  preview.url = nil
  preview.cmd = nil
end

-- `maki.net.request` upgrades http:// to https:// and blocks loopback, so a
-- dev server on localhost is invisible to it. Probe with a process instead
-- (curl, then wget as a fallback): no host allowlist, no upgrade.
local function port_open(host, port)
  local cmd
  if maki.fn.executable("curl") == 1 then
    cmd = string.format("curl -s -o /dev/null -m 2 http://%s:%d/", host, port)
  elseif maki.fn.executable("wget") == 1 then
    cmd = string.format("wget -q -T 2 -O /dev/null http://%s:%d/", host, port)
  else
    return nil, "neither curl nor wget is available to probe the dev server"
  end
  local id = maki.fn.jobstart(cmd)
  if not id then
    return false
  end
  local res = maki.fn.jobwait(id, 4000)
  -- A non-zero exit still means the port answered (e.g. 404); only a
  -- refused/timed-out connection fails to reach the server at all.
  return res ~= nil
end

local function wait_for_preview(url, timeout_s)
  local host, port = url:match("^https?://([^:/]+):(%d+)")
  if not host then
    return false, "cannot parse host:port from " .. url
  end
  port = tonumber(port)
  local deadline = os.time() + timeout_s
  while os.time() < deadline do
    local open, probe_err = port_open(host, port)
    if open == nil then
      return false, probe_err
    end
    if open then
      return true
    end
    if not preview_alive() then
      return false, "the dev server exited before it answered"
    end
    maki.async.sleep(300) -- shared Lua thread: must yield, or the host kills it at 5s
  end
  return false, "timed out waiting for " .. url
end

-- ── tools ───────────────────────────────────────────────────────────────────

maki.api.register_tool({
  name = "design_preview",
  kind = "browser",
  description = [[Start the project's dev server and return the local URL so the browser tools can see the live app.

Framework-agnostic: with no `command`, it looks for an npm `dev`/`start`/`serve` script and runs it, assuming `http://localhost:<preview_port>`. Pass `command`/`url` to override (e.g. `python3 -m http.server 3000` for static HTML). The server keeps running between calls; `design_preview_stop` or a plugin reload tears it down. Next: `browser_launch` at the returned URL, then `browser_screenshot`.]],
  schema = {
    type = "object",
    additionalProperties = false,
    properties = {
      command = { type = "string", description = "Shell command to start the server (default: detected npm dev script)." },
      url = { type = "string", description = "URL the server will serve (default: http://localhost:<preview_port>)." },
      port = { type = "integer", description = "Port to assume for the detected server (default: preview_port option)." },
    },
  },
  handler = function(input, ctx)
    if preview_alive() and preview.url and not input.command then
      return { llm_output = string.format("Dev server already running at %s (cmd: %s).", preview.url, preview.cmd) }
    end
    if preview.job_id then
      stop_preview()
    end

    local cmd = input.command
    local guessed = false
    if not cmd then
      cmd = detect_dev_command()
      guessed = true
    end
    if not cmd then
      return {
        llm_output = "error: no dev server detected. Pass `command` (e.g. `npm run dev`, `python3 -m http.server 3000`) and `url`.",
        is_error = true,
      }
    end

    local dir = ensure_design_dir()
    if not dir then
      return { llm_output = "error: cannot create .maki/design", is_error = true }
    end
    local log = maki.fs.joinpath(dir, "preview.log")
    local job_id, start_err = maki.fn.jobstart(cmd, {
      stdout = log,
      stderr = log,
      scope = "plugin",
      tail = 40,
      name = "design_preview",
    })
    if not job_id then
      return { llm_output = "error: " .. (start_err or "could not start the dev server"), is_error = true }
    end
    preview.job_id = job_id
    preview.cmd = cmd
    preview.log = log

    local url = input.url or ("http://localhost:" .. (input.port or config.preview_port))
    preview.url = url

    local ok, wait_err = wait_for_preview(url, config.preview_timeout)
    if not ok then
      local tail = maki.fs.read(log) or ""
      stop_preview()
      return {
        llm_output = string.format("error: %s\ncommand: %s\n--- log ---\n%s", wait_err, cmd, tail),
        is_error = true,
      }
    end

    local note = guessed and " (auto-detected)" or ""
    return {
      llm_output = string.format("Dev server ready at %s%s\ncommand: %s\nlog: %s", url, note, cmd, log),
      written_path = log,
    }
  end,
  header = function(input) return input.command or "detect dev server" end,
})

maki.api.register_tool({
  name = "design_preview_stop",
  kind = "browser",
  description = "Stop the dev server started by design_preview.",
  schema = { type = "object", additionalProperties = false, properties = {} },
  handler = function()
    if preview.job_id then
      stop_preview()
      return { llm_output = "Dev server stopped." }
    end
    return { llm_output = "No dev server running." }
  end,
})

maki.api.register_tool({
  name = "design_viewports",
  kind = "read",
  description = [[Return the design viewport matrix (name, width, height) to screenshot against, and any saved design notes.

Call this at the start of a design task to know which breakpoints to check. For each entry, launch the browser at that size (`browser_launch` with viewport_width/height) and `browser_screenshot` the page; those return images you can actually see.]],
  schema = { type = "object", additionalProperties = false, properties = {} },
  handler = function()
    local lines = { "Viewports to check:" }
    for _, name in ipairs(VIEWPORT_ORDER) do
      local v = VIEWPORTS[name]
      lines[#lines + 1] = string.format("- %s: %dx%d", name, v[1], v[2])
    end
    local dir = design_dir()
    local notes = maki.fs.read(maki.fs.joinpath(dir, "notes.md"))
    if notes and notes ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Design notes so far:"
      lines[#lines + 1] = notes
    end
    return { llm_output = table.concat(lines, "\n") }
  end,
})

maki.api.register_tool({
  name = "design_note",
  kind = "read",
  description = [[Record a human design note (feedback, taste call, constraint) into the running notes file, or read existing notes back.

Notes persist under `.maki/design/notes.md` across iterations. Call with `text` to append; call with no arguments to list them.]],
  schema = {
    type = "object",
    additionalProperties = false,
    properties = {
      text = { type = "string", description = "Note to append (omit to list notes)." },
      author = { type = "string", description = "Who wrote it (default: user)." },
    },
  },
  handler = function(input)
    local dir, err = ensure_design_dir()
    if not dir then
      return { llm_output = "error: " .. err, is_error = true }
    end
    local path = maki.fs.joinpath(dir, "notes.md")
    if not input.text or input.text == "" then
      local body = maki.fs.read(path)
      if not body or body == "" then
        return { llm_output = "No design notes yet." }
      end
      return { llm_output = body, written_path = path }
    end
    local author = input.author or "user"
    local line = string.format("- [%s] %s: %s\n", os.date("%Y-%m-%d %H:%M"), author, input.text)
    local _, write_err = maki.fs.append(path, line)
    if write_err then
      return { llm_output = "error: " .. write_err, is_error = true }
    end
    return { llm_output = "Noted: " .. input.text, written_path = path }
  end,
  header = function(input) return input.text and ("note: " .. input.text) or "notes" end,
})

-- ── commands ────────────────────────────────────────────────────────────────

local function set_active(on)
  active = on
  maki.ui.set_status_hint(on and { { "design", "on" } } or nil)
end

maki.api.register_command({
  name = "/design",
  description = "Toggle design mode (UI/UX persona + preview loop)",
  nargs = "?",
  handler = function(cmd)
    local arg = (cmd.args or ""):match("^%s*(.-)%s*$")
    if arg == "off" or (arg == "" and active) then
      set_active(false)
      maki.ui.flash("Design mode off")
      return
    end
    set_active(true)
    maki.ui.flash("Design mode on")
  end,
})

maki.api.register_command({
  name = "/design-note",
  description = "Add a human design note for the current iteration",
  nargs = "+",
  handler = function(cmd)
    local text = (cmd.args or ""):match("^%s*(.-)%s*$")
    if text == "" then
      maki.ui.flash("usage: /design-note <text>")
      return
    end
    local dir = ensure_design_dir()
    if not dir then
      maki.ui.flash("cannot resolve .maki/design")
      return
    end
    local path = maki.fs.joinpath(dir, "notes.md")
    local _, err = maki.fs.append(path, string.format("- [%s] user: %s\n", os.date("%Y-%m-%d %H:%M"), text))
    maki.ui.flash(err and ("note failed: " .. err) or "Design note added")
    local id = maki.session.current()
    if id then
      maki.session.notify("Design note from the user: " .. text, { session = id })
    end
  end,
})

maki.keymap.set("n", "<C-g>", function()
  set_active(not active)
  maki.ui.flash(active and "Design mode on" or "Design mode off")
end, { desc = "Toggle design mode" })

maki.api.create_autocmd("plugin_unload", {
  callback = function()
    stop_preview()
    maki.ui.set_status_hint(nil)
  end,
})

return M
