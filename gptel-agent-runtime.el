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
;; Host configuration is expected to define personal paths such as
;; `my/data-dir' before requiring this package.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar my/data-dir (expand-file-name "~/emacs/")
  "Personal data/config root supplied by the host Emacs configuration.
This fallback keeps the package loadable when it is required outside Denis's
normal init path.")

;; Module load order (respects the dependency DAG).
(require 'gar-core)        ; defgroup + ~50 defcustoms + all cl-defstructs + base helpers
(require 'gar-substrate)   ; tick, event pump, evidence, versioned state
(require 'gar-quarantine)  ; per-source quarantine + promote + pre-flight conflict check
(require 'gar-skeptic)     ; Advocatus Diaboli skeptic (rule-based + model-based)
(require 'gar-policy)      ; policy broker, capability gate, presets, context wrappers
(require 'gar-mission-control) ; unified runtime dashboard
(require 'gar-canaries)    ; prompt-injection canary suite (wraps gar-policy's untrusted-context)
(require 'gar-memory)      ; sessions, embedding cache, novelty, synthesis, hypothesis-test
(require 'gar-tools)       ; tool registry, native gptel tools, tool-invention pipeline
(require 'gar-backend)     ; Ollama runtime utilities + model-id normalization
(require 'gar-directives)  ; emacs-local-assistant / planner / assistant directives
(require 'gar-context)     ; image capture + web fetch helpers
(require 'gar-executor)    ; Response Executor (formerly claude-executor-*; aliases kept)
(require 'gar-agents)      ; agent/skill/org-unit/playbook registries + chat + model router
(require 'gar-loop)        ; autonomous execution loop + worker dispatcher

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
(when (and (boundp 'my/gptel-ollama-backend)
           my/gptel-ollama-backend)
  (gptel-agent-runtime-use-default-local-model))

;; Finish wiring gar-tools' global tool list now that my/gptel-tools-all
;; is defined (it lives in gar-core which loads before gar-tools, so
;; this with-eval-after-load runs only when gptel itself is loaded).
(with-eval-after-load 'gptel
  (when (and (fboundp 'my/gptel-tools-all)
             (boundp 'gptel-use-tools))
    (setq gptel-use-tools t
          gptel-tools (my/gptel-tools-all))))

(provide 'gptel-agent-runtime)

;;; gptel-agent-runtime.el ends here
