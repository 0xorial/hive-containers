# hive — rules for agents

## Node workspaces are ALWAYS bound to a Mac folder

Never create a volume-backed node. The owner must be able to inspect every
node's workspace from the host filesystem — agent work inside a container
without that overview is not acceptable. `config/bind-root` makes this the
default (`hive new <name>` binds `<bind-root>/<name>`); do not pass
`--no-bind`, and do not remove or empty `config/bind-root`, unless the owner
explicitly asks.

## Other standing rules

- `hive <node> github on` creates a private GitHub repo `<owner>/<node>` as a
  side effect when the workspace has no origin — say so before running it.
  `hive new <name> --github` is the one-shot form (scaffold, first commit,
  repo, push) and carries the same side effect: same rule.
- Never push, and never use credentials found inside a node, without asking.
- This checkout is what `hive up` runs. Test `bin/hive` changes with a
  throwaway node (`hive new <x> --no-dind`, then `hive rm <x> --purge` and
  remove the workspace) before relying on them.
