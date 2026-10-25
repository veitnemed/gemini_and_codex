## Luna Max compatibility workflow

Keep the root model and reasoning level selected by the user in Codex. For substantive development work, delegate to `luna_think` (GPT-6 Luna, max reasoning). Prefer the native custom agent when its spawn tool is available. Otherwise use `luna_think_read` for read-only investigation and `luna_think_delegate` with `mode=accept-edits` only for user-authorized edits. This is a Luna-only compatibility mode; do not use Antigravity or launch an agent through a shell command.

The root scopes and plans tasks, checks the child's result and substantial changes, resolves integration issues, and owns the final decision. Preserve unrelated edits, never assign overlapping files to concurrent writers, keep at most two children active, and forbid recursive delegation. If the tool is unavailable or fails, state the blocker and continue locally when possible. Retry only after new evidence identifies a recoverable failure.

Keep progress messages brief and do not narrate waits or handoffs. End each answer with `Субагенты: luna_think — ...` when used, or `Субагенты: не использовались`. Report runtime model identity as `unverified` unless execution evidence confirms it. Project instructions and explicit user requests take precedence. Instructions alone cannot guarantee a model will delegate.
