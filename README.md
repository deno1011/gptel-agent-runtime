# gptel-agent-runtime

Emacs-native agent runtime scaffolding built on top of
[gptel](https://github.com/karthink/gptel).

This repository was extracted from Denis Butic's private Emacs configuration so
the AI implementation can evolve as a standalone package and later be prepared
for MELPA.

## Current Status

- Package-shaped first extraction.
- Literate source: edit `gptel-agent-runtime.org` first.
- Generated package artifact: `gptel-agent-runtime.el`.
- Agent/skill registry scaffold with a lightweight router.
- Autonomous execution loop: observe, plan, delegate, act with tools,
  observe result, reflect, remember, and continue.
- Worker records for parallel safe/read tool and direct-response substeps.
- Deterministic JSON repair plus schema validation for planner/reviewer JSON.
- Lexical memory retrieval, optional Ollama embedding retrieval, and session resume.
- Skill outcome statistics, richer verification, and safety policies for tool execution.
- Installs from Git via `package-vc-install`.
- `main` and `stable` initially point to the same current version.
- The implementation is still monolithic and keeps compatibility names such as
  `my/gptel-*` and `claude-executor-*`.

## Installation From Emacs

```elisp
(package-vc-install
 '(gptel-agent-runtime
   :url "https://github.com/deno1011/gptel-agent-runtime"
   :branch "main"))
(require 'gptel-agent-runtime)
```

## Agents And Skills

The package includes first-class registries for agents and skills:

- agents describe specialist roles such as `assistant`, `planner`, `executor`,
  `reviewer`, and `memory-curator`
- skills describe reusable strategies such as `inline-rendering`,
  `web-research`, `org-task-management`, `code-change`, and `memory-update`
- a lightweight router matches recent task text to skills and selects an agent
- `gptel-send` applies the route by appending relevant skill instructions to
  the active system message

Useful inspection command:

```elisp
(gptel-agent-runtime-route-summary
 "plot a 3d math function inline and search current rules")
```

## Autonomous Loop

`M-x gptel-agent-runtime-start` starts the first autonomous session loop:

1. observe the current Emacs/workspace context
2. ask the planner for strict JSON steps
3. delegate each step to an agent role
4. execute `direct_response`, `remember`, or a native gptel tool with JSON args
5. record observations and tool results
6. ask the reviewer for JSON reflection
7. write session memory and continue, replan, finish, or fail

The planner can mark safe/read steps with `"parallel": true`. Those steps are
launched as independent worker records and can run direct responses, read-only
file/buffer/Org tools, and web search/fetch tools. Mutating tools stay
serialized behind safety policy.

The loop retrieves relevant prior memory before planning. Retrieval defaults to
lexical matching and can optionally use Ollama embeddings with
`gptel-agent-runtime-memory-retrieval-method`. Sessions are written as readable
Elisp data and can be resumed with `M-x gptel-agent-runtime-resume-last-session`
or `M-x gptel-agent-runtime-resume-session`.

Planner/reviewer JSON is repaired for common local-model mistakes and then
validated against runtime schemas before execution. Verification checks are
tool/skill-aware for web research, inline rendering, writes, Org mutations,
exports, and code execution.

Useful inspection commands:

```elisp
(gptel-agent-runtime-session-summary)
(gptel-agent-runtime-describe-session)
(gptel-agent-runtime-resume-last-session)
```

This is a real loop now, but it is still conservative. Parallelism is limited
to safe/read workers, embedding retrieval depends on a local Ollama embedding
model being available, and local model planner quality still determines how
good the JSON steps are.

## Development Notes

- Do not develop directly in `gptel-agent-runtime.el`. It is tangled from
  `gptel-agent-runtime.org`.
- After editing the Org source, run:

```sh
emacs --batch --eval '(require (quote org))' \
  --eval '(org-babel-tangle-file "gptel-agent-runtime.org")'
```

- Validate the generated file with `check-parens` and a batch load smoke test.
- The package currently expects the host config to define personal paths such
  as `my/data-dir` before loading.
- The next cleanup should split the monolithic file into core, backends,
  prompts, executor, tools, context, and planner modules.
- Before MELPA submission, remove personal defaults, reduce top-level side
  effects, add autoloads, and add ERT smoke tests.
