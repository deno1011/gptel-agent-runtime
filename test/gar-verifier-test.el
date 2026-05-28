;;; gar-verifier-test.el --- ERT tests for gar-verifier -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-verifier-test--step (&rest plist)
  "Build a plan-step for testing."
  (apply #'gptel-agent-runtime-plan-step-create
         (append plist
                 (list :id (or (plist-get plist :id) "vstep-1")
                       :title (or (plist-get plist :title) "test step")
                       :risk (or (plist-get plist :risk) 'write)))))

(defun gar-verifier-test--result (status &rest plist)
  "Build an action-result with STATUS and PLIST overrides."
  (apply #'gptel-agent-runtime-action-result-create
         (append plist
                 (list :status status
                       :tool (or (plist-get plist :tool) "write_file")))))

;; --- applies-p ---

(ert-deftest gar-verifier-applies-on-write-risk ()
  "Verifier fires for write/shell/destructive risk and not for read/safe."
  (let ((gptel-agent-runtime-verifier-mode 'rule-based))
    (should (gptel-agent-runtime--verifier-applies-p 'write))
    (should (gptel-agent-runtime--verifier-applies-p 'shell))
    (should (gptel-agent-runtime--verifier-applies-p 'destructive))
    (should-not (gptel-agent-runtime--verifier-applies-p 'safe))
    (should-not (gptel-agent-runtime--verifier-applies-p 'read))))

(ert-deftest gar-verifier-applies-not-when-off ()
  "When mode is `off' the verifier never fires."
  (let ((gptel-agent-runtime-verifier-mode 'off))
    (should-not (gptel-agent-runtime--verifier-applies-p 'write))
    (should-not (gptel-agent-runtime--verifier-applies-p 'destructive))))

;; --- rule-based verdicts ---

(ert-deftest gar-verifier-rule-based-passes-on-ok-status ()
  "Rule-based verdict is passed=t when status=ok and output is benign."
  (let* ((step (gar-verifier-test--step))
         (result (gar-verifier-test--result 'ok :output "Written: /tmp/x"))
         (verdict (gptel-agent-runtime--verifier-rule-based-verdict
                   step result)))
    (should (plist-get verdict :passed))
    (should (eq 'rule-based (plist-get verdict :mode)))
    (should-not (plist-get verdict :suggested-correction))))

(ert-deftest gar-verifier-rule-based-fails-on-error-status ()
  "Rule-based verdict is passed=nil when status=error."
  (let* ((step (gar-verifier-test--step))
         (result (gar-verifier-test--result
                  'error :error "Permission denied"))
         (verdict (gptel-agent-runtime--verifier-rule-based-verdict
                   step result)))
    (should-not (plist-get verdict :passed))
    (should (string-match-p "status=error"
                            (plist-get verdict :reason)))
    (should (stringp (plist-get verdict :suggested-correction)))))

(ert-deftest gar-verifier-rule-based-fails-on-error-keyword-in-output ()
  "An output that begins with `Error: ...' is flagged even when status=ok."
  (let* ((step (gar-verifier-test--step))
         (result (gar-verifier-test--result
                  'ok :output "Error: file not found"))
         (verdict (gptel-agent-runtime--verifier-rule-based-verdict
                   step result)))
    (should-not (plist-get verdict :passed))
    (should (string-match-p "error keyword"
                            (plist-get verdict :reason)))))

(ert-deftest gar-verifier-rule-based-passes-when-output-just-mentions-error ()
  "Output that MENTIONS `error' mid-text but does not begin with it passes.
This is the over-flag-avoidance contract: the regex is anchored on \\`."
  (let* ((step (gar-verifier-test--step))
         (result (gar-verifier-test--result
                  'ok :output "Wrote 42 lines about error handling."))
         (verdict (gptel-agent-runtime--verifier-rule-based-verdict
                   step result)))
    (should (plist-get verdict :passed))))

;; --- dispatcher ---

(ert-deftest gar-verifier-dispatcher-returns-nil-when-off ()
  "When mode is off, verify-action-result returns nil and records nothing."
  (let* ((gptel-agent-runtime-verifier-mode 'off)
         (gptel-agent-runtime--last-verifier-verdicts nil)
         (step (gar-verifier-test--step))
         (result (gar-verifier-test--result 'ok :output "ok")))
    (should-not (gptel-agent-runtime-verify-action-result step result))
    (should (null gptel-agent-runtime--last-verifier-verdicts))))

(ert-deftest gar-verifier-dispatcher-records-verdict-when-rule-based ()
  "verify-action-result pushes verdicts onto --last-verifier-verdicts."
  (let* ((gptel-agent-runtime-verifier-mode 'rule-based)
         (gptel-agent-runtime--last-verifier-verdicts nil)
         (step (gar-verifier-test--step))
         (result (gar-verifier-test--result 'ok :output "Written: /tmp/x"))
         (verdict (gptel-agent-runtime-verify-action-result step result)))
    (should verdict)
    (should (= 1 (length gptel-agent-runtime--last-verifier-verdicts)))))

(ert-deftest gar-verifier-dispatcher-skips-safe-risk ()
  "Safe steps are not verified even in rule-based mode."
  (let* ((gptel-agent-runtime-verifier-mode 'rule-based)
         (gptel-agent-runtime--last-verifier-verdicts nil)
         (step (gar-verifier-test--step :risk 'safe))
         (result (gar-verifier-test--result 'ok :output "ok")))
    (should-not (gptel-agent-runtime-verify-action-result step result))))

;; --- should-retry-p semantics ---

(ert-deftest gar-verifier-should-retry-when-failed-with-correction ()
  "Retry is queued when passed=nil and a non-empty correction is present."
  (let* ((step (gar-verifier-test--step :attempts 1))
         (verdict '(:passed nil :suggested-correction "Use a real path"
                    :mode rule-based)))
    (should (gptel-agent-runtime--verifier-should-retry-p step verdict))))

(ert-deftest gar-verifier-should-not-retry-when-passed ()
  "passed=t never triggers a retry."
  (let* ((step (gar-verifier-test--step :attempts 1))
         (verdict '(:passed t :suggested-correction "Use a real path"
                    :mode rule-based)))
    (should-not (gptel-agent-runtime--verifier-should-retry-p step verdict))))

(ert-deftest gar-verifier-should-not-retry-when-no-correction ()
  "Retry requires a non-empty correction to be queued."
  (let* ((step (gar-verifier-test--step :attempts 1))
         (verdict '(:passed nil :suggested-correction ""
                    :mode rule-based)))
    (should-not (gptel-agent-runtime--verifier-should-retry-p step verdict))))

(ert-deftest gar-verifier-should-not-retry-when-attempts-exceed-max ()
  "When attempts >= max-retries + 1, no more retries are queued."
  (let* ((gptel-agent-runtime-verifier-max-retries 2)
         ;; max-retries=2 means initial attempt + 2 retries = 3 attempts max
         (step (gar-verifier-test--step :attempts 3))
         (verdict '(:passed nil :suggested-correction "Try X"
                    :mode rule-based)))
    (should-not (gptel-agent-runtime--verifier-should-retry-p step verdict))))

;; --- prepare-retry mutates step correctly ---

(ert-deftest gar-verifier-prepare-retry-mutates-step ()
  "prepare-retry appends correction to rationale and sets status to pending."
  (let* ((step (gar-verifier-test--step
                :attempts 1
                :rationale "Original rationale."))
         (verdict '(:passed nil
                    :reason "Output empty."
                    :suggested-correction "Pass an explicit path."
                    :mode rule-based)))
    (gptel-agent-runtime--verifier-prepare-retry step verdict)
    (should (eq 'pending (gptel-agent-runtime-plan-step-status step)))
    (let ((r (gptel-agent-runtime-plan-step-rationale step)))
      (should (string-match-p "Original rationale" r))
      (should (string-match-p "VERIFIER REJECTED" r))
      (should (string-match-p "Pass an explicit path" r)))))

;; --- parse-verdict on prose-wrapped JSON (delegates to skeptic-model
;; balanced-brace scanner; ensures the integration works end-to-end) ---

(ert-deftest gar-verifier-parse-verdict-handles-embedded-json ()
  "Parser pulls a well-formed verdict out of prose-wrapped model output."
  (let* ((text "Verdict: {\"passed\": false, \"confidence\": 0.7, \"reason\": \"empty output\", \"suggested_correction\": \"add a path arg\"}. Done.")
         (step (gar-verifier-test--step))
         (result (gar-verifier-test--result 'ok :output ""))
         (verdict (gptel-agent-runtime--verifier-parse-verdict
                   text step result)))
    (should verdict)
    (should-not (plist-get verdict :passed))
    (should (= 0.7 (plist-get verdict :confidence)))
    (should (eq 'model-based (plist-get verdict :mode)))
    (should (string-match-p "path arg"
                            (plist-get verdict :suggested-correction)))))

(ert-deftest gar-verifier-parse-verdict-returns-nil-on-garbage ()
  "Parser returns nil on input with no JSON, so the caller can fall back."
  (let* ((step (gar-verifier-test--step))
         (result (gar-verifier-test--result 'ok :output "")))
    (should-not (gptel-agent-runtime--verifier-parse-verdict
                 "no json here" step result))))

(provide 'gar-verifier-test)

;;; gar-verifier-test.el ends here
