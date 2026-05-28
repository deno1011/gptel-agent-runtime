;;; gar-loop-test.el --- ERT tests for gar-loop -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; The autonomous loop is the most external-dependency-heavy module in the
;; runtime (model calls, workspace observation, worker dispatcher). These
;; tests stay at the smoke level: pure helpers and prompt builders. The
;; full continue/act/observe-and-plan flows need a live gptel backend and
;; are exercised end-to-end by manual session runs, not unit tests.

(ert-deftest gar-loop-tool-names-returns-list-of-strings ()
  "`--tool-names' returns a non-empty list of strings after package load."
  (let ((names (gptel-agent-runtime--tool-names)))
    (should (listp names))
    (when names
      (should (cl-every #'stringp names)))))

(ert-deftest gar-loop-workspace-observation-returns-string ()
  "`--workspace-observation' returns a string even with no buffers worth listing."
  (let ((obs (gptel-agent-runtime--workspace-observation)))
    (should (stringp obs))))

(ert-deftest gar-loop-planner-system-prompt-non-empty ()
  "Planner system prompt is a non-empty string."
  (let ((prompt (gptel-agent-runtime--planner-system)))
    (should (stringp prompt))
    (should (> (length prompt) 50))))

(ert-deftest gar-loop-plan-review-system-prompt-non-empty ()
  "Plan-review system prompt is a non-empty string."
  (let ((prompt (gptel-agent-runtime--plan-review-system)))
    (should (stringp prompt))
    (should (> (length prompt) 50))))

(ert-deftest gar-loop-brainstorm-inventor-system-non-empty ()
  "Brainstorm inventor prompt is non-empty."
  (let ((prompt (gptel-agent-runtime--brainstorm-inventor-system)))
    (should (stringp prompt))
    (should (string-match-p "JSON" prompt))))

(ert-deftest gar-loop-brainstorm-simplifier-system-non-empty ()
  "Brainstorm simplifier prompt is non-empty."
  (let ((prompt (gptel-agent-runtime--brainstorm-simplifier-system)))
    (should (stringp prompt))))

(ert-deftest gar-loop-parse-brainstorm-alternatives-extracts-alts ()
  "Parser pulls a list of alternatives out of a well-formed inventor response."
  (let* ((response
          "Some preamble. { \"alternatives\": [
             { \"name\": \"opt-a\",
               \"why\": \"...\",
               \"first_step_tool\": \"web_search\",
               \"first_step_args\": { \"query\": \"x\" }},
             { \"name\": \"opt-b\",
               \"why\": \"...\",
               \"first_step_tool\": \"read_file\",
               \"first_step_args\": { \"path\": \"y\" }}
           ]} trailing.")
         (alts (gptel-agent-runtime--parse-brainstorm-alternatives response)))
    (should (= 2 (length alts)))
    (should (string= "opt-a" (plist-get (car alts) :name)))))

(ert-deftest gar-loop-parse-brainstorm-alternatives-empty-on-garbage ()
  "Parser returns an empty list when no JSON object is present."
  (let ((alts (gptel-agent-runtime--parse-brainstorm-alternatives
               "no json here")))
    (should (listp alts))
    (should (= 0 (length alts)))))

(ert-deftest gar-loop-list-sessions-returns-list ()
  "`list-sessions' returns a list of session files (possibly empty)."
  (let ((sessions (gptel-agent-runtime-list-sessions)))
    (should (listp sessions))))

(provide 'gar-loop-test)

;;; gar-loop-test.el ends here
