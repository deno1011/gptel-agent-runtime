;;; gptel-agent-runtime.el --- Emacs-native agent runtime on top of gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Denis Butic

;; Author: Denis Butic
;; Maintainer: Denis Butic
;; URL: https://github.com/deno1011/gptel-agent-runtime
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))
;; Keywords: convenience, tools, ai, gptel

;;; Commentary:

;; Thin master entrypoint for the multi-file gptel-agent-runtime
;; package. After the 2026-05-27 monolith split, every concern lives in
;; a dedicated `gar-*' module. This file pulls them in in dependency
;; order and runs the small tail-of-load wiring that needs to happen
;; only after every module has loaded.
;;
;; Host configuration MAY define `my/data-dir' before requiring this
;; package to override the default data directory. When `my/data-dir'
;; is bound at require time, this file forwards its value into the
;; package's own `gptel-agent-runtime-data-directory' defcustom (see
;; gar-core); when it is not bound, the defcustom's default
;; (`user-emacs-directory') is used. The package itself no longer bakes
;; in a personal path like `~/emacs/'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; Backwards-compat shim: some host configs define `my/data-dir' before
;; requiring this package, and some modules (notably gar-directives) read
;; the variable at LOAD TIME to bake the value into directive prompts. To
;; keep both paths working: defvar with `user-emacs-directory' as the
;; default so a fresh install sees a sensible non-nil value, but let any
;; pre-bound host value win (defvar is a no-op when the variable is
;; already bound). The package's canonical setting is
;; `gptel-agent-runtime-data-directory' in gar-core; the tail-of-load
;; wiring below forwards whatever value `my/data-dir' ended up with into
;; that defcustom so the rest of the runtime sees a single source of
;; truth.
(defvar my/data-dir user-emacs-directory
  "Personal data root, optionally pre-bound by the host config.
When the host config sets this before requiring the package, that value
is forwarded into `gptel-agent-runtime-data-directory' at the tail of
the master load sequence. New setups should customise
`gptel-agent-runtime-data-directory' directly.")

;; Module load order (respects the dependency DAG).
(require 'gar-core)        ; defgroup + ~50 defcustoms + all cl-defstructs + base helpers
(require 'gar-substrate)   ; tick, event pump, evidence, versioned state
(require 'gar-quarantine)  ; per-source quarantine + promote + pre-flight conflict check
(require 'gar-skeptic)     ; Advocatus Diaboli core (rule-based + dispatcher)
(require 'gar-skeptic-model) ; model-based skeptic verdict path
(require 'gar-verifier)    ; post-execution verifier + auto-retry signal
(require 'gar-validator)   ; JSON-Schema-inspired tool-arg validator
(require 'gar-policy)      ; policy broker, capability gate, presets, context wrappers
(require 'gar-mission-control) ; unified runtime dashboard
(require 'gar-canaries)    ; prompt-injection canary suite (wraps gar-policy's untrusted-context)
(require 'gar-memory)      ; sessions, embedding cache, novelty, synthesis, hypothesis-test
(require 'gar-trajectory)  ; per-goal trajectory storage (substrate for learning loop)
(require 'gar-tools)       ; tool registry, native gptel tools, tool-invention pipeline
(require 'gar-backend)     ; Ollama runtime utilities + model-id normalization
(require 'gar-directives)  ; emacs-local-assistant / planner / assistant directives
(require 'gar-context)     ; image capture + web fetch helpers
(require 'gar-executor)    ; Response Executor (formerly claude-executor-*; aliases kept)
(require 'gar-agents)      ; agent/skill/org-unit/playbook registries + chat + model router
(require 'gar-loop)        ; autonomous execution loop + worker dispatcher

;; If the host config set `my/data-dir' before requiring us, forward
;; that value into the package's own data-directory defcustom so the
;; rest of the runtime sees a single source of truth. Setting only
;; happens when the host explicitly opted in -- the defcustom's default
;; (`user-emacs-directory') wins on a fresh install.
(when (and (boundp 'my/data-dir)
           (stringp my/data-dir)
           (boundp 'gptel-agent-runtime-data-directory))
  (setq gptel-agent-runtime-data-directory
        (file-name-as-directory my/data-dir)))

;; Tail-of-load wiring. These steps need to run only AFTER every module
;; has finished loading because they consult cross-module helpers.

;; Activate the Response Executor (defined in gar-executor) now that
;; every module has loaded. The function is `gar-response-executor-mode';
;; the legacy `claude-executor-mode' name remains available via
;; `defalias' for any user config that still binds it.
(when (fboundp 'gar-response-executor-mode)
  (gar-response-executor-mode 1))

;; Select the local model only after directives, tools, and
;; compatibility helpers have been defined.
(when (and (boundp 'gptel-agent-runtime-ollama-backend)
           gptel-agent-runtime-ollama-backend)
  (gptel-agent-runtime-use-default-local-model))

;; Finish wiring gar-tools' global tool list now that gptel-agent-runtime-tools-all
;; is defined (it lives in gar-core which loads before gar-tools, so
;; this with-eval-after-load runs only when gptel itself is loaded).
(with-eval-after-load 'gptel
  (when (and (fboundp 'gptel-agent-runtime-tools-all)
             (boundp 'gptel-use-tools))
    (setq gptel-use-tools t
          gptel-tools (gptel-agent-runtime-tools-all))))

(provide 'gptel-agent-runtime)

;;; gptel-agent-runtime.el ends here
