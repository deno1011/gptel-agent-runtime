;;; test-helper.el --- shared setup for gar-* ERT smoke tests -*- lexical-binding: t; -*-

;; Loads the full gptel-agent-runtime package once so individual test files
;; can assume every gar-* feature is provided. Discovers gptel on `load-path'
;; by trying the user's installed package path; tests fall back to whatever
;; gptel is already on `load-path' if that directory is missing.

;;; Code:

;; Always prefer .el over a stale .elc. Without this, a byte-compiled
;; master from an earlier commit can mask freshly-extracted modules and
;; cause spurious `void-function' failures in batch tests. The compiler
;; only emits a warning, not an error, so the bad load slips through
;; silently otherwise. Set this BEFORE the (require) below.
(setq load-prefer-newer t)

(defvar gar-test-package-root
  (or (and load-file-name
           (file-name-directory
            (directory-file-name (file-name-directory load-file-name))))
      default-directory)
  "Directory holding the gar-*.el sources under test.")

(defvar gar-test-gptel-path
  (car (file-expand-wildcards
        (expand-file-name "~/.emacs.d/elpa/gptel-*")))
  "Directory holding the installed gptel package, when available.")

(unless (featurep 'gptel)
  (when (and gar-test-gptel-path (file-directory-p gar-test-gptel-path))
    (add-to-list 'load-path gar-test-gptel-path)))
(add-to-list 'load-path gar-test-package-root)

(require 'cl-lib)
(require 'ert)
(require 'gptel-agent-runtime)

;; Defensive: tests must never write to the user's real SQLite at
;; ~/.emacs.d/gptel-agent-runtime/agent.sqlite.  Disable the SQLite
;; mirror globally for the duration of any test run.  Tests that
;; genuinely exercise the SQLite layer (gar-memory-sqlite-test) and
;; tests that go through the e2e sandbox (gar-test-fake-llm) re-enable
;; it explicitly within their let-binding, scoped to a temp DB file.
;;
;; Before this guard, gar-trajectory-test let-bound the trajectories
;; directory to a temp path but forgot the sqlite-file -- every
;; record-trajectory call wrote a "Test goal: write a file" row into
;; the real agent.sqlite.  ~40 of those leaked into the user's archive
;; over a single day of CI runs.
(setq gptel-agent-runtime-sqlite-enabled nil)

(provide 'test-helper)

;;; test-helper.el ends here
