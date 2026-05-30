;;; gar-live-test-shared.el --- helpers shared across live-LLM test files -*- lexical-binding: t; -*-

;; Synchronous gptel-request wrapper + a single configurable timeout,
;; used by both the Ollama-targeted `gar-live-model-test' and the
;; Anthropic-targeted `gar-live-claude-test'.  Keeping this in a
;; separate file means either test file can be loaded alone without
;; pulling in the other backend's test registry.

;;; Code:

(require 'cl-lib)

(defvar gar-live-test--request-timeout 90
  "Seconds to wait for a single live-LLM response before failing.
Set high enough to tolerate a cold-loaded local model OR a slow
remote API; tests are still gated by GAR_RUN_SLOW so the suite
default isn't paying for it.")

(defun gar-live-test--sync-request (prompt &rest args)
  "Send PROMPT via `gptel-request' and block until the response arrives.
ARGS are forwarded to `gptel-request' (except :callback, which is
supplied here).  Returns the response string, or signals on timeout."
  (let* ((done nil)
         (result nil)
         (cb (lambda (response _info)
               (setq result response done t)))
         (deadline (+ (float-time) gar-live-test--request-timeout)))
    (apply #'gptel-request prompt
           :callback cb
           args)
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (unless done
      (error "Live LLM request timed out after %ds"
             gar-live-test--request-timeout))
    result))

(provide 'gar-live-test-shared)

;;; gar-live-test-shared.el ends here
