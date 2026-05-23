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
