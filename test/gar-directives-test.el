;;; gar-directives-test.el --- ERT tests for gar-directives -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-directives-test--emacs-local-assistant-string ()
  "Return the current `emacs-local-assistant' directive string from
`gptel-directives'."
  (alist-get 'emacs-local-assistant gptel-directives))

(ert-deftest gar-directives-emacs-local-assistant-is-registered ()
  "The emacs-local-assistant directive is present in `gptel-directives'."
  (let ((d (gar-directives-test--emacs-local-assistant-string)))
    (should (stringp d))
    (should (> (length d) 200))))

(ert-deftest gar-directives-emacs-local-assistant-has-tool-output-faithfulness ()
  "PR 10 directive change: emacs-local-assistant carries the
TOOL OUTPUT FAITHFULNESS section so the model is instructed to relay
tool list output verbatim instead of summarising."
  (let ((d (gar-directives-test--emacs-local-assistant-string)))
    (should (stringp d))
    (should (string-match-p "TOOL OUTPUT FAITHFULNESS" d))
    (should (string-match-p "MUST include all N[[:space:]]+items" d))
    (should (string-match-p "Do NOT pick a thematic subset" d))))

;; --- PR 12: directive selection is no longer backend-conditional ---

(ert-deftest gar-directives-current-runtime-returns-rich-directive ()
  "PR 12: every backend, local or remote, gets the rich
`emacs-local-assistant' directive.  The thin `emacs-assistant'
variant left Haiku and other small remote models without the
CRITICAL RULES / TOOL OUTPUT FAITHFULNESS / ORG FILES guidance
that they need.  Now both code paths return the rich one."
  (should (eq 'emacs-local-assistant
              (gptel-agent-runtime-directive-for-current-runtime))))

(ert-deftest gar-directives-choice-returns-rich-directive ()
  "Same for `directive-for-choice' regardless of model string."
  (dolist (m '("claude-haiku-4-5-20251001"
               "claude-opus-4-7"
               "gpt-4o-mini"
               "qwen2.5:14b-instruct"
               "llama3.2"))
    (should (eq 'emacs-local-assistant
                (gptel-agent-runtime-directive-for-choice m)))))

(provide 'gar-directives-test)

;;; gar-directives-test.el ends here
