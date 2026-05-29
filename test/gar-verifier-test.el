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

;; ============================================================================
;; PR 10: completeness check
;; ============================================================================

;; --- item count extraction ---

(ert-deftest gar-verifier-item-count-empty-text-is-zero ()
  (should (= 0 (gptel-agent-runtime--verifier-extract-item-count nil)))
  (should (= 0 (gptel-agent-runtime--verifier-extract-item-count ""))))

(ert-deftest gar-verifier-item-count-detects-todo-state-brackets ()
  "Counts entries shaped like `[TODO] ...' (the get_todos tool format)."
  (let ((text "[TODO] First task\n[NEXT] Second task\n[WAIT] Third\n[REVIEW] Fourth"))
    (should (= 4 (gptel-agent-runtime--verifier-extract-item-count text)))))

(ert-deftest gar-verifier-item-count-detects-markdown-numbered ()
  (let ((text "1. one\n2. two\n3. three\n4. four\n5. five"))
    (should (= 5 (gptel-agent-runtime--verifier-extract-item-count text)))))

(ert-deftest gar-verifier-item-count-detects-bullets ()
  (let ((text "- a\n- b\n- c\n* d\n+ e"))
    (should (= 5 (gptel-agent-runtime--verifier-extract-item-count text)))))

(ert-deftest gar-verifier-item-count-detects-org-todos ()
  (let ((text "* TODO First\n** NEXT Sub\n* WAIT Other\n** REVIEW Y"))
    (should (= 4 (gptel-agent-runtime--verifier-extract-item-count text)))))

(ert-deftest gar-verifier-item-count-prose-returns-zero ()
  "Free-form prose without list shape returns 0."
  (should (= 0 (gptel-agent-runtime--verifier-extract-item-count
                "Just some sentences. No list here."))))

;; --- heuristic completeness verdict ---

(defun gar-verifier-test--make-result (output &optional tool)
  (gptel-agent-runtime-action-result-create
   :status 'ok :output output :tool (or tool "direct_response")))

(ert-deftest gar-verifier-completeness-heuristic-passes-when-all-items-present ()
  (let* ((prior (gar-verifier-test--make-result
                 "[TODO] a\n[TODO] b\n[TODO] c\n[TODO] d"))
         (resp (gar-verifier-test--make-result
                "1. a\n2. b\n3. c\n4. d"))
         (step (gar-verifier-test--step :id "s2" :risk 'safe
                                        :title "Render response"))
         (v (gptel-agent-runtime--verifier-completeness-heuristic-verdict
             step resp prior)))
    (should (plist-get v :passed))
    (should (eq 'completeness-heuristic (plist-get v :mode)))))

(ert-deftest gar-verifier-completeness-heuristic-fails-when-summarised ()
  (let* ((prior (gar-verifier-test--make-result
                 "[TODO] a\n[TODO] b\n[TODO] c\n[TODO] d\n[TODO] e\n[TODO] f\n[TODO] g\n[TODO] h\n[TODO] i\n[TODO] j"))
         (resp (gar-verifier-test--make-result
                "1. a\n2. b\n3. c"))
         (step (gar-verifier-test--step :id "s2" :risk 'safe
                                        :title "Render response"))
         (v (gptel-agent-runtime--verifier-completeness-heuristic-verdict
             step resp prior)))
    (should (not (plist-get v :passed)))
    (should (stringp (plist-get v :suggested-correction)))
    (should (string-match-p "EVERY item" (plist-get v :suggested-correction)))))

;; --- applies-p ---

(ert-deftest gar-verifier-completeness-applies-when-prior-has-enough-items ()
  (let* ((prior (gar-verifier-test--make-result
                 "[TODO] 1\n[TODO] 2\n[TODO] 3\n[TODO] 4"))
         (step (gar-verifier-test--step :suggested-tool "direct_response"))
         (gptel-agent-runtime-verifier-completeness-mode 'heuristic)
         (gptel-agent-runtime-verifier-completeness-min-items 3))
    (should (gptel-agent-runtime--verifier-completeness-applies-p step prior))))

(ert-deftest gar-verifier-completeness-not-applies-when-mode-off ()
  (let* ((prior (gar-verifier-test--make-result
                 "[TODO] 1\n[TODO] 2\n[TODO] 3\n[TODO] 4"))
         (step (gar-verifier-test--step :suggested-tool "direct_response"))
         (gptel-agent-runtime-verifier-completeness-mode 'off))
    (should-not (gptel-agent-runtime--verifier-completeness-applies-p
                 step prior))))

(ert-deftest gar-verifier-completeness-not-applies-below-min-items ()
  (let* ((prior (gar-verifier-test--make-result "[TODO] only one"))
         (step (gar-verifier-test--step :suggested-tool "direct_response"))
         (gptel-agent-runtime-verifier-completeness-mode 'heuristic)
         (gptel-agent-runtime-verifier-completeness-min-items 3))
    (should-not (gptel-agent-runtime--verifier-completeness-applies-p
                 step prior))))

(ert-deftest gar-verifier-completeness-not-applies-for-non-trigger-tool ()
  (let* ((prior (gar-verifier-test--make-result
                 "[TODO] 1\n[TODO] 2\n[TODO] 3\n[TODO] 4"))
         (step (gar-verifier-test--step :suggested-tool "write_file"))
         (gptel-agent-runtime-verifier-completeness-mode 'heuristic))
    (should-not (gptel-agent-runtime--verifier-completeness-applies-p
                 step prior))))

;; --- find prior tool result ---

(ert-deftest gar-verifier-find-prior-tool-result-skips-current-and-pending ()
  "Returns the most recent prior `done' step's result, skipping the
current step and any non-done steps that came after."
  (let* ((s1 (gptel-agent-runtime-plan-step-create
              :id "a" :title "Read"
              :status 'done
              :result (gar-verifier-test--make-result
                       "[TODO] x\n[TODO] y\n[TODO] z")))
         (s2 (gptel-agent-runtime-plan-step-create
              :id "b" :title "Render"
              :status 'running))
         (plan (gptel-agent-runtime-plan-create
                :id "p" :status 'active :steps (list s1 s2)))
         (task (gptel-agent-runtime-task-create
                :id "t" :goal "g" :notes plan)))
    (let ((prior (gptel-agent-runtime--verifier-find-prior-tool-result
                  s2 task)))
      (should prior)
      (should (gptel-agent-runtime-action-result-p prior))
      (should (string-match-p "x"
                              (gptel-agent-runtime-action-result-output
                               prior))))))

;; --- end-to-end dispatcher ---

(ert-deftest gar-verifier-verify-action-result-returns-failing-completeness ()
  "When completeness fails for a direct_response step, dispatcher
returns the failing completeness verdict even though the primary
verifier sees no problem."
  (let* ((gptel-agent-runtime-verifier-mode 'rule-based)
         (gptel-agent-runtime-verifier-completeness-mode 'heuristic)
         (gptel-agent-runtime-verifier-completeness-min-items 3)
         (gptel-agent-runtime-verifier-completeness-min-ratio 0.5)
         (s1 (gptel-agent-runtime-plan-step-create
              :id "a" :title "Read"
              :status 'done
              :result (gar-verifier-test--make-result
                       "[TODO] one\n[TODO] two\n[TODO] three\n[TODO] four\n[TODO] five\n[TODO] six\n[TODO] seven\n[TODO] eight")))
         (s2 (gptel-agent-runtime-plan-step-create
              :id "b" :title "Render" :status 'running
              :suggested-tool "direct_response" :risk 'safe))
         (plan (gptel-agent-runtime-plan-create
                :id "p" :status 'active :steps (list s1 s2)))
         (task (gptel-agent-runtime-task-create
                :id "t" :goal "g" :notes plan))
         (resp (gar-verifier-test--make-result "1. one\n2. two")))
    (let ((verdict (gptel-agent-runtime-verify-action-result s2 resp task)))
      (should verdict)
      (should (not (plist-get verdict :passed)))
      (should (eq 'completeness-heuristic (plist-get verdict :mode)))
      (should (stringp (plist-get verdict :suggested-correction))))))

(provide 'gar-verifier-test)

;;; gar-verifier-test.el ends here
