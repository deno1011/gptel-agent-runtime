;;; gar-skeptic-model-test.el --- ERT tests for gar-skeptic-model -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- JSON parsing path (these used to live in gar-skeptic-test.el before
;; gar-skeptic-model split out on 2026-05-28) ---

(ert-deftest gar-skeptic-model-parse-verdict-handles-embedded-json ()
  "Parser extracts the JSON object from prose-wrapped model output."
  (let* ((text "Some prose. {\"risk\":\"medium\",\"concerns\":[\"a\",\"b\"],\"recommended_mitigations\":[\"x\"]} trailing.")
         (verdict (gptel-agent-runtime--skeptic-parse-verdict text "t" "a")))
    (should (eq (plist-get verdict :risk) 'medium))
    (should (equal (plist-get verdict :concerns) '("a" "b")))
    (should (equal (plist-get verdict :recommended-mitigations) '("x")))
    (should (eq (plist-get verdict :mode) 'model-based))))

(ert-deftest gar-skeptic-model-parse-verdict-returns-nil-on-no-json ()
  "Parser returns nil on input with no JSON object so the caller can fall back."
  (should-not (gptel-agent-runtime--skeptic-parse-verdict
               "no json here" "t" "a")))

(ert-deftest gar-skeptic-model-extract-json-object-handles-nested-braces ()
  "Balanced-brace scanner returns the full outer object across nested braces."
  (let ((out (gptel-agent-runtime--skeptic-extract-json-object
              "prose {{\"a\":1}, ignore}{ok} more")))
    (should (equal out "{{\"a\":1}, ignore}"))))

(ert-deftest gar-skeptic-model-build-prompt-includes-tool-and-args ()
  "User-prompt builder includes the tool name, agent, risk class, and args."
  (let ((prompt (gptel-agent-runtime--skeptic-build-prompt
                 "shell" (list :command "rm -rf /") 'destructive
                 '(shell-exec) "researcher")))
    (should (string-match-p "tool: shell" prompt))
    (should (string-match-p "agent: researcher" prompt))
    (should (string-match-p "destructive" prompt))
    (should (string-match-p "shell-exec" prompt))
    (should (string-match-p "rm -rf" prompt))))

(ert-deftest gar-skeptic-model-system-prompt-non-empty ()
  "System prompt is non-empty (either from agent registry or fallback constant)."
  (let ((prompt (gptel-agent-runtime--skeptic-system-prompt)))
    (should (stringp prompt))
    (should (> (length prompt) 50))))

(provide 'gar-skeptic-model-test)

;;; gar-skeptic-model-test.el ends here
