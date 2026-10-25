# Luna Codex Orchestrator v1.3.1

The EXE carries its own Node.js runtime and offers three persistent workflows: 1.3
(`Fast / Plan / Think`) is the default, while 1.2 (`Luna Max`) is a Luna-only
compatibility mode, not a reinstall of the older Antigravity release. The root
model selected by the user remains unchanged. Default is ordinary Codex without
managed Luna routing; it removes the managed policy, MCP entries, and unchanged
managed roles while restoring prior `[agents]` settings. The runtime stays on
disk for switching back. All modes apply to future chats.
The candidate EXE installs three native Codex
custom agents plus three distinct MCP server registrations. The main Codex model
is whatever the user selects in the client. The installed global policy asks the
main agent to delegate the substantive step of development work, to retain
scoping and verification, and to report which children actually worked.

## Installation layout

- `CODEX_HOME` if set, otherwise `%USERPROFILE%\.codex`.
- `config.toml`: one managed `# workflow-mode=...` marker, `[agents]` setting for enablement and a two-child
  limit, plus `mcp_servers.luna_fast`, `.luna_think`, and `.luna_plan`.
- Active global `AGENTS.override.md` when present and nonempty, otherwise
  `AGENTS.md`: the managed routing policy.
- `agents/luna_fast.toml`, `agents/luna_think.toml`, `agents/luna_plan.toml`:
  fixed model and effort for native custom agents.
- `tools/luna-orchestrator/v1.3.1`: Node runtime, MCP bridge, and Node license.
- Normal global installation also saves `Luna-Control.exe` there and creates a
  `Luna Codex` desktop shortcut. The GUI installs 1.3 automatically on a fresh
  profile, displays the active mode, and persists each button's choice in the
  managed MCP block. Default is persisted as a marker-only managed block, and
  saved modes survive updates. Mode changes apply to new Codex sessions after restart.
- `backups/luna-orchestrator-*`: original file snapshots and a restore manifest
  for each nontrivial install or uninstall.

The MCP registrations are three independently visible profiles backed by the
same bridge code. They are not separate Marketplace plugin packages. Each bridge
process advertises only its own tools. Fast and Think expose a separately
annotated read-only `read` tool alongside `check` and the write-capable
`delegate` tool. Plan exposes only read-only `check` and `delegate` tools.
MCP approval mode `writes` lets the safe tools run without a routine prompt;
write-capable calls still follow Codex approvals. `luna_plan` refuses edit mode
at both schema and execution time. The child CLI receives `-m
gpt-6-luna`, its fixed reasoning effort, a nonrecursive marker, and a sandbox
chosen for read-only planning or user-authorized edits. It keeps `CODEX_HOME`
for authentication while ignoring parent user configuration in the child.

## Routing and verification

The root agent prefers native custom agents and falls back to the corresponding
MCP profile if native spawning is unavailable. For implementation, debugging,
refactoring, tests, or multi-file investigation, the policy requires a child
before substantive root work. Fast is the first choice for bounded work, Plan
for uncertain multi-component work, and Think only for objectively hard
reasoning. Trivial questions and tiny one-line edits may be direct. A bridge or
network error does not justify switching to Think. The root verifies substantial
changes and avoids overlapping writers. The policy calls for at most two
concurrent children. The MCP fallback
uses two shared process leases and one shared write lease across the three server
processes. Native agents still rely on the Codex two-child limit and the root's
file-scope decisions.

Custom-agent configuration and MCP registration make the roles available in new
Codex sessions. Even the stricter instruction cannot force a model to call an
agent on every qualifying request. Two fresh CLI tasks with the previous softer
policy finished without delegation; the stricter policy needs a fresh live test.
The UI displays actual tool calls, and the global policy asks for a concise
`Субагенты:` line in the final answer. If no child ran, it says so. A model name
in TOML or the bridge's requested-model field alone does not prove which model
the service executed; runtime identity remains `unverified` without process or
structured execution evidence. API token prices are not subscription-limit
percentages, and this release makes no quantified savings claim.

## Updating, uninstalling, and testing

The native Windows controller uses a restrained light sidebar and white workspace
with rounded mode buttons and an explicit active selection, based on the
[official Codex desktop reference](https://developers.openai.com/images/blog/long-horizon-4.jpeg).
It retains the Luna Codex identity and native window controls. Switching a mode
starts the installer asynchronously and disables mode changes until it finishes.

The EXE opens the workflow picker when run normally, and accepts `--mode 1.3|1.2|default`, `--status` and `--uninstall`; command-line installation can use
`--quiet` and `--codex-home PATH` for an isolated test profile. Installation
removes the old managed Antigravity MCP/instruction blocks and the legacy
unmarked Antigravity delegation section when it matches the known heading and
tool name. It preserves other instructions, unrelated TOML tables, and the
root model. It refuses to overwrite user-owned role files or MCP tables.
Uninstall removes managed settings and unchanged managed role files; backup
snapshots remain for recovery. The unused bundled runtime may remain on disk.

Offline checks:

```powershell
node tests/test-luna-bridge-offline.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-luna-exe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-luna-installer.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-luna-ui.ps1
```

The installer test uses a temporary `CODEX_HOME`, checks repeat installation,
Codex TOML parsing when the CLI is available, uninstall, and a user-owned role
collision. It does not make model requests. Restart Codex and open a new chat
after installing: existing chats can keep their earlier tool inventory.

The UI test runs actual button handlers for 1.3 -> 1.2 -> default -> 1.3 against a fresh
profile under the Windows temporary directory, verifies persistence and user
settings, and writes rendered screenshots of all three active selections. The
smoke sequence uses explicit loaded, busy, and active-mode state rather than
parsing translated labels. It does not modify the real profile.
