# maki-design-plugin

Turn your [maki](https://github.com/tontinton/maki) coding agent into a UI/UX/frontend designer.

A `/design` mode that swaps maki's persona for a design specialist and pairs it with a preview + screenshot feedback loop. Toggle it on, point the agent at a frontend, and it will start a dev server, look at the rendered result, critique it, change it, and look again — instead of only reasoning about the code.

<img width="2548" height="2310" alt="screenshot" src="https://github.com/user-attachments/assets/b8886c44-21aa-4fc5-96bf-03b78389e107" />

## How it works

`/design` flips two things at once, both through maki's prompt-slot API (no changes to maki itself):

- The singleton `identity` and `tone` slots switch to a design persona, and an aggregate `conventions` hint carries the full design workflow — the loop, the screenshot-reading checklist, and the rules. Toggling off restores maki's built-in text exactly. Because the slot content is a function re-evaluated before every run, the change reaches the model as a context update, so the prompt cache survives the switch.
- Four tools are registered for the preview loop. Rendering is delegated to the companion [maki-browser-plugin](https://github.com/basvk/maki-browser-plugin): `browser_screenshot` already returns PNGs as vision input, so the agent can actually *see* the page it is designing.

Design state and artifacts live under `.maki/design/` in the project: `preview.log` for the dev server and `notes.md` for human feedback.

### The feedback loop

1. `design_preview` starts the project's dev server and returns a local URL.
2. `browser_launch` opens it; `browser_screenshot` returns images the agent can see, across a viewport matrix.
3. The agent critiques what it sees (hierarchy, spacing, contrast, states), changes one thing, reloads, and screenshots again.
4. `/design-note <text>` lets you inject a taste call, which the agent folds into the next iteration.

## Tools

Four tools are registered under the `design` plugin:

| Tool | Description |
| --- | --- |
| `design_preview` | Start the project's dev server (auto-detects an npm `dev`/`start`/`serve` script, or takes an explicit `command`/`url`) and return the local URL once it answers. |
| `design_preview_stop` | Stop the dev server started by `design_preview`. |
| `design_viewports` | Return the viewport matrix (mobile/tablet/desktop) to screenshot against, plus any saved design notes. |
| `design_note` | Append a human design note to `.maki/design/notes.md`, or read existing notes back. |

Screenshots and page interaction come from the browser plugin's own tools (`browser_launch`, `browser_screenshot`, `browser_click`, `browser_evaluate`, …).

## Prerequisites

- **[maki-browser-plugin](https://github.com/basvk/maki-browser-plugin)** — required for the screenshot feedback loop. Install it first, along with its prerequisites (Node.js + Playwright/Chromium):
  ```sh
  npm install playwright
  npx playwright install chromium
  ```
- **A dev server for your frontend** — an npm `dev`/`start`/`serve` script, or any command you pass to `design_preview` (e.g. `python3 -m http.server 3000` for static HTML).

## Install

1. **Copy `design.lua`** into your maki Lua directory:
   ```sh
   cp design.lua ~/.config/maki/lua/
   ```

2. **Load it** from your maki init file (`~/.config/maki/init.lua`), after the browser plugin:
   ```lua
   require("browser")
   require("design")
   ```

3. **Set permissions** in `~/.config/maki/plugin.toml` — the plugin needs `run` (to start the dev server) and `fs_read`/`fs_write` (for the preview log and notes):
   ```toml
   [permissions]
   run = true
   fs_read = true
   fs_write = true
   ```

4. Run `/reload` in maki. The first run after loading rebuilds the frame once (adding tools and prompt slots changes the fingerprint), so you may see a one-time "prompt was rebuilt" notice.

## Usage

Toggle design mode:

```
/design
```

or press `<C-g>`. A `design` status hint appears while it is on. Toggle off with `/design` again or `/design off`.

Then just describe the design task:

```
Design review the landing page at localhost:5173. Check it at mobile, tablet and desktop,
name the three worst visual problems, and fix the top one.
```

Add a taste call at any point:

```
/design-note the primary button is too small on mobile
```

> While design mode is on, the plugin owns the `identity`/`tone` prompt slots, so any other `identity`/`tone` customization is shadowed by it. Turning it off restores maki's built-in defaults exactly.

### Watching the model work

The model writes everything it produces into `.maki/design/`, and the plugin keeps that visible:

- **Toggling on** flashes the artifacts directory, and the status bar shows the live preview URL once the dev server is up.
- **The preview URL** is meant to be opened in your own browser — the model states it in prose after starting the server, so you can watch the page update live as it iterates. (Clickability depends on your terminal: most emulators, e.g. iTerm2, WezTerm, Kitty, Ghostty, linkify `http://` URLs on Cmd/Ctrl-click.)
- **`/design-view`** opens a panel listing the preview URL, the notes, and the artifact/log paths — so you can see what the model produced without hunting through directories.

```
/design-view
```

The artifacts themselves:

| Path | What it is |
| --- | --- |
| `.maki/design/preview.log` | Dev-server output (startup errors land here). |
| `.maki/design/notes.md` | Your `/design-note` feedback, read back to the model each iteration. |
| `.maki/browser/<run>/` | Network/download/console artifacts the browser plugin saves during a session. |

Screenshots the model takes are **not** written to disk — `browser_screenshot` returns them straight to the model, so you see them inline in the transcript. To watch the page yourself, use the preview URL.

## Configuration

The plugin keeps its settings in a plain table rather than `register_options` (that call is once-per-plugin, and every file `require`d from `init.lua` shares the `global` namespace, so the browser plugin already claims it). Override via `setup`:

```lua
require("design").setup({
  preview_port = 5173,    -- port design_preview assumes for a detected dev server (default 3000)
  preview_timeout = 30,   -- seconds to wait for the server to answer (default 20)
})
```

## Credits

This plugin was generated 100% by DeepSeek, in a maki session, alongside its human operator.

## License

MIT
