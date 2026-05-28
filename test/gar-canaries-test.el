;;; gar-canaries-test.el --- ERT tests for gar-canaries -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(ert-deftest gar-canaries-runner-returns-results-shape ()
  "`run-injection-canaries' returns one (NAME PASS-P REASON) per defcustom entry."
  (let ((results (gptel-agent-runtime-run-injection-canaries)))
    (should (= (length results)
               (length gptel-agent-runtime-injection-canaries)))
    (dolist (r results)
      (should (= 3 (length r)))
      (should (stringp (nth 0 r)))
      ;; PASS-P is truthy/nil. The runner's (and ...) returns the last
      ;; truthy match position; the docstring contract is truthy = pass.
      (should (stringp (nth 2 r))))))

(ert-deftest gar-canaries-all-pass-with-default-wrapper ()
  "Every canary passes when `wrap-untrusted-context' is enabled (default)."
  (let ((gptel-agent-runtime-wrap-untrusted-context t)
        (results (gptel-agent-runtime-run-injection-canaries)))
    (dolist (r results)
      (should (nth 1 r)))))

(ert-deftest gar-canaries-populates-last-results-defvar ()
  "Runner updates `--last-canary-results' for the mission-control summary."
  (gptel-agent-runtime-run-injection-canaries)
  (should (= (length gptel-agent-runtime--last-canary-results)
             (length gptel-agent-runtime-injection-canaries))))

(provide 'gar-canaries-test)

;;; gar-canaries-test.el ends here
