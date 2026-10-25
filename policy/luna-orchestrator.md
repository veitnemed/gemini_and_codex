## Luna orchestration for every new Codex task

Keep the root model and reasoning level selected by the user in Codex. For a development request that involves implementation, debugging, refactoring, tests, or investigation across more than one file, delegate the substantive work before doing it yourself. The user need not mention agents. A quick `git status` and a small file inventory are allowed to define scope and protect existing edits. Do not use confidence, expected overhead, or the ability to solve the task yourself as a reason to skip delegation. Answer trivial questions and make tiny one-line changes directly.

### Route the first substantial step

- For bounded implementation, focused debugging, routine tests, and local checks, call `luna_fast` (`gpt-6-luna`, medium) first.
- For ambiguous requirements, a design question spanning components, or a change needing a concrete implementation plan, call `luna_plan` (`gpt-6-luna`, high, read-only) first. Give it one concise planning task. Then give the bounded implementation to Fast unless the plan establishes a specific hard reasoning problem.
- Call `luna_think` (`gpt-6-luna`, max) only for substantial architecture, difficult cross-component reasoning, or a Fast failure whose evidence points to reasoning complexity. Infrastructure, permission, and timeout failures are not reasons to switch to Think.

Use a native Codex custom agent when its spawn tool is available. Otherwise, use the matching MCP profile: `luna_fast_read` or `luna_think_read` for read-only work, `luna_plan_delegate` for read-only planning, and `luna_fast_delegate` or `luna_think_delegate` with `mode=accept-edits` only for user-authorized edits. The bridge validates availability. Do not call a writable `delegate` tool with `mode=plan` when its dedicated read-only tool is available. If no suitable child tool is available or a launch fails, report that fact and its reason, then continue the task yourself if possible. Never claim that a configured profile ran when no child call completed. Do not launch an agent through a shell command. Do not use Antigravity.

The root scopes tasks, chooses the role, reviews the child's result, checks substantial changes and tests, resolves integration issues, and makes the final decision. Do not repeat the child's investigation or implementation without evidence of a defect. Keep at most two children active, never assign overlapping edits to concurrent writers, and forbid recursive delegation. Retry only after new evidence identifies a recoverable failure.

### Keep the conversation compact

The Codex UI shows agent tool calls and child threads. Give a brief progress update when a material phase changes or a long task needs one; do not narrate each wait, retry, or handoff. At the end of every request, include one short line: `Субагенты: luna_plan — ...; luna_fast — ...; luna_think — ...` listing only roles actually used, or `Субагенты: не использовались`. Mark a runtime model `unverified` when execution data cannot confirm it.

Project instructions and the user's request take precedence. This rule makes delegation mandatory for the specified development work when tools are available; instructions alone cannot provide a runtime guarantee that the model will obey it.
