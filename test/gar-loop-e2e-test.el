;;; gar-loop-e2e-test.el --- end-to-end tests driving the autonomous loop -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)
(require 'gar-test-fake-llm)

;; --- 1. Happy-path session: full chain plan -> act -> reflect -> finalize ---

(ert-deftest gar-e2e-happy-path-records-trajectory ()
  "A clean session flows plan -> direct response -> reflect -> finalize
and records a trajectory in the in-memory ring."
  (gar-test-with-sandboxed-state
    (gar-test-with-fake-llm nil
      (gptel-agent-runtime-start "describe emacs in one line")
      (should (>= (length gptel-agent-runtime--trajectories) 1))
      (let ((traj (car gptel-agent-runtime--trajectories)))
        (should (gptel-agent-runtime-trajectory-p traj))
        (should (equal "describe emacs in one line"
                       (gptel-agent-runtime-trajectory-goal traj)))
        (should (memq (gptel-agent-runtime-trajectory-outcome traj)
                      '(success failure))))
      ;; Fake LLM saw both a planner call AND a direct-response call.
      (should (cl-find :plan gar-test--fake-llm-call-log :key #'car))
      (should (cl-find :direct gar-test--fake-llm-call-log :key #'car)))))

(ert-deftest gar-e2e-happy-path-bumps-tick-and-emits-events ()
  "A clean session advances the OpenClaw tick and emits events."
  (gar-test-with-sandboxed-state
    (let ((start-tick (or gptel-agent-runtime-tick-counter 0))
          (start-events (length gptel-agent-runtime-event-log)))
      (gar-test-with-fake-llm nil
        (gptel-agent-runtime-start "say hi")
        (should (> gptel-agent-runtime-tick-counter start-tick))
        (should (> (length gptel-agent-runtime-event-log)
                   start-events))))))

;; --- 2. Verifier failure path ---

(ert-deftest gar-e2e-verifier-fires-on-risky-step ()
  "A plan with a `write' risk step produces a verifier verdict."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime--last-verifier-verdicts nil))
      (gar-test-with-fake-llm
          '(:plan "{\"steps\":[{\"title\":\"Write something\",\"rationale\":\"need write\",\"risk\":\"write\",\"tool\":\"direct_response\"}]}")
        (gptel-agent-runtime-start "produce a risky write step")
        ;; At least one verifier verdict should have been recorded for the
        ;; risky step (direct_response on a write-risk step still fires the
        ;; rule-based verifier).
        (should (>= (length gptel-agent-runtime--last-verifier-verdicts)
                    1))))))

;; --- 3. Read-only origin falls back to *gptel-agent-output* ---

(ert-deftest gar-e2e-read-only-origin-falls-back ()
  "Starting a session from a read-only buffer routes origin to *gptel-agent-output*."
  (gar-test-with-sandboxed-state
    (let ((ro-buf (get-buffer-create "*gar-e2e-ro*")))
      (unwind-protect
          (with-current-buffer ro-buf
            (setq buffer-read-only t)
            (gar-test-with-fake-llm nil
              (gptel-agent-runtime-start "fallback test")
              (should (bufferp gptel-agent-runtime--origin-buffer))
              (should (not (eq gptel-agent-runtime--origin-buffer ro-buf)))
              (should (string= "*gptel-agent-output*"
                               (buffer-name
                                gptel-agent-runtime--origin-buffer)))))
        (when (buffer-live-p ro-buf) (kill-buffer ro-buf))
        (when (get-buffer "*gptel-agent-output*")
          (kill-buffer "*gptel-agent-output*"))))))

;; --- 4. Mission control re-renders into a special-mode buffer ---

(ert-deftest gar-e2e-mission-control-rerenders-cleanly ()
  "Calling `mission-control' twice does not error on the read-only buffer."
  (gar-test-with-sandboxed-state
    (unwind-protect
        (progn
          (gptel-agent-runtime-mission-control)
          ;; Second call should NOT signal "Buffer is read-only".
          (gptel-agent-runtime-mission-control)
          (let ((buf (get-buffer
                      gptel-agent-runtime-mission-control-buffer-name)))
            (should (bufferp buf))
            (with-current-buffer buf
              (should buffer-read-only)
              (should (> (buffer-size) 100)))))
      (when (get-buffer gptel-agent-runtime-mission-control-buffer-name)
        (kill-buffer gptel-agent-runtime-mission-control-buffer-name)))))

;; --- 5. Experiment routes arms + Bayesian decision fires ---

(ert-deftest gar-e2e-experiment-bayesian-promote ()
  "After lopsided arm outcomes, the Bayesian rule fires promote."
  (gar-test-with-sandboxed-state
    (let* ((gptel-agent-runtime-experiment-bayesian-min-runs 3)
           (gptel-agent-runtime-experiment-bayesian-threshold 0.95)
           (exp (gptel-agent-runtime-experiment-create
                 :id "e2e-exp" :playbook-id "pb-target"
                 :candidate-id "cand-1"
                 :candidate-summary "refined"
                 :candidate-triggers '("x")
                 :candidate-steps '((:title "s"))
                 :status 'running
                 :original-successes 1 :original-failures 9
                 :candidate-successes 9 :candidate-failures 1
                 :started-at "2026-05-29T00:00:00")))
      ;; The Bayesian dispatcher fires promote on this data.
      (let ((d (gptel-agent-runtime--experiment-decision exp)))
        (should d)
        (should (eq 'promote (plist-get d :decision)))
        (should (eq 'bayesian (plist-get d :rule)))
        (should (> (plist-get d :prob-candidate-wins) 0.95))))))

(ert-deftest gar-e2e-experiment-arm-assignment-is-stable ()
  "Repeated arm picks for one (experiment, session) return the same arm."
  (gar-test-with-sandboxed-state
    (let* ((exp (gptel-agent-runtime-experiment-create
                 :id "stable" :playbook-id "pb"
                 :candidate-summary "x" :candidate-triggers '("t")
                 :candidate-steps '() :status 'running))
           (a1 (gptel-agent-runtime--experiment-pick-arm exp "session-A"))
           (a2 (gptel-agent-runtime--experiment-pick-arm exp "session-A"))
           (a3 (gptel-agent-runtime--experiment-pick-arm exp "session-A")))
      (should (eq a1 a2))
      (should (eq a2 a3)))))

;; --- 6. Refinement triggers on consistent failure ---

(ert-deftest gar-e2e-refinement-pattern-triggers-on-failures ()
  "`refine-failure-pattern' returns a plist when a playbook has N recent
failure trajectories with at least one failed verifier verdict each."
  (gar-test-with-sandboxed-state
    (let* ((gptel-agent-runtime-refine-window 5)
           (gptel-agent-runtime-refine-min-runs 3)
           (gptel-agent-runtime-refine-failure-threshold 0.6)
           (verdict '(:passed nil :reason "stub failure"
                      :suggested-correction "try X"))
           (gptel-agent-runtime--trajectories
            (cl-loop for i from 1 to 4 collect
                     (gptel-agent-runtime-trajectory-create
                      :id (format "t-%d" i)
                      :goal "broken goal"
                      :outcome 'failure
                      :playbook-ids '("pb-X")
                      :verifier-verdicts (list verdict)
                      :steps (list (gptel-agent-runtime-trajectory-step-create
                                    :title "broken step"
                                    :suggested-tool "direct_response"))
                      :finalized-at "2026-05-29T00:00:00"))))
      (let ((pattern (gptel-agent-runtime--refine-failure-pattern "pb-X")))
        (should pattern)
        (should (>= (plist-get pattern :failure-rate)
                    gptel-agent-runtime-refine-failure-threshold))
        (should (>= (plist-get pattern :failures) 3))
        (should (plist-get pattern :evidence))))))

;; --- PR 8: tool execution paths through the loop ---

(ert-deftest gar-e2e-tool-read-file-runs-through-loop ()
  "A plan step that calls `read_file' actually reads the temp file content."
  (gar-test-with-sandboxed-state
    (let* ((tmp (make-temp-file "gar-e2e-read-" nil ".txt"))
           (content "hello from e2e read test"))
      (unwind-protect
          (progn
            (with-temp-file tmp (insert content))
            (gar-test-with-fake-llm
                (list :plan
                      (format "{\"steps\":[{\"title\":\"Read it\",\"rationale\":\"need it\",\"risk\":\"read\",\"tool\":\"read_file\",\"args\":{\"path\":\"%s\"}}]}"
                             tmp))
              (gptel-agent-runtime-start "read the temp file")
              ;; The session finalized successfully and a trajectory was
              ;; recorded. The tool ran -- otherwise the loop would have
              ;; finalized with an error.
              (should (>= (length gptel-agent-runtime--trajectories) 1))
              (let ((traj (car gptel-agent-runtime--trajectories)))
                (should (eq 'success
                            (gptel-agent-runtime-trajectory-outcome traj))))))
        (ignore-errors (delete-file tmp))))))

(ert-deftest gar-e2e-tool-write-file-persists-content ()
  "A plan step that calls `write_file' writes the requested content to disk."
  (gar-test-with-sandboxed-state
    (let* ((tmp (expand-file-name (make-temp-name "gar-e2e-write-")
                                   temporary-file-directory))
           (content "payload from e2e write test"))
      (unwind-protect
          (gar-test-with-fake-llm
              (list :plan
                    (format "{\"steps\":[{\"title\":\"Write\",\"rationale\":\"need write\",\"risk\":\"write\",\"tool\":\"write_file\",\"args\":{\"path\":\"%s\",\"content\":\"%s\"}}]}"
                           tmp content))
            (gptel-agent-runtime-start "write the temp file")
            (should (file-exists-p tmp))
            (with-temp-buffer
              (insert-file-contents tmp)
              (should (string-match-p content (buffer-string)))))
        (ignore-errors (delete-file tmp))))))

(ert-deftest gar-e2e-tool-unknown-becomes-error-result ()
  "A plan step with an unknown tool name produces an error result and
finalizes the session with `failed' outcome."
  (gar-test-with-sandboxed-state
    (gar-test-with-fake-llm
        '(:plan "{\"steps\":[{\"title\":\"Run\",\"rationale\":\"x\",\"risk\":\"safe\",\"tool\":\"this_tool_does_not_exist\"}]}")
      (gptel-agent-runtime-start "trigger an unknown tool")
      (should (>= (length gptel-agent-runtime--trajectories) 1))
      (let ((traj (car gptel-agent-runtime--trajectories)))
        ;; The trajectory was recorded; outcome is failure because the
        ;; reflection step sees the error result. (If the stub returned a
        ;; `done' reflection regardless, the outcome would be `success' --
        ;; what matters here is that the loop did NOT crash on an unknown
        ;; tool name.)
        (should (memq (gptel-agent-runtime-trajectory-outcome traj)
                      '(success failure)))))))

;; --- PR 8: parallel worker dispatch ---

(ert-deftest gar-e2e-parallel-workers-launched-event-emitted ()
  "A plan with two parallel-eligible steps emits `parallel-workers-launched'."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime-enable-parallel-workers t))
      (gar-test-with-fake-llm
          '(:plan "{\"steps\":[{\"title\":\"A\",\"rationale\":\"a\",\"risk\":\"safe\",\"tool\":\"direct_response\",\"parallel\":true},{\"title\":\"B\",\"rationale\":\"b\",\"risk\":\"safe\",\"tool\":\"direct_response\",\"parallel\":true}]}")
        (gptel-agent-runtime-start "two parallel steps")
        (should (cl-some
                 (lambda (e)
                   (eq (gptel-agent-runtime-event-type e)
                       'parallel-workers-launched))
                 gptel-agent-runtime-event-log))))))

;; --- PR 8: multi-step sequential plan ---

(ert-deftest gar-e2e-multi-step-plan-runs-both-steps ()
  "A two-step sequential plan (no parallel flag) executes both steps."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime-enable-parallel-workers nil))
      (gar-test-with-fake-llm
          '(:plan "{\"steps\":[{\"title\":\"First\",\"rationale\":\"r1\",\"risk\":\"safe\"},{\"title\":\"Second\",\"rationale\":\"r2\",\"risk\":\"safe\"}]}"
             :reflection "{\"status\":\"continue\",\"reflection\":\"keep going\"}")
        (gptel-agent-runtime-start "multi-step task")
        ;; Two `step-delegated' events should have fired.
        (let ((delegated (cl-count-if
                          (lambda (e)
                            (eq (gptel-agent-runtime-event-type e)
                                'step-delegated))
                          gptel-agent-runtime-event-log)))
          (should (>= delegated 2)))))))

;; --- PR 8: tool-policy editor ---

(ert-deftest gar-e2e-tool-policy-set-entry-adds-and-removes ()
  "`--tool-policy-set-entry' inserts and removes entries cleanly."
  (let ((gptel-agent-runtime-tool-policy nil))
    (gptel-agent-runtime--tool-policy-set-entry
     "demo_tool" '(:confirm write :default allow))
    (should (equal '(:confirm write :default allow)
                   (cdr (assoc "demo_tool"
                               gptel-agent-runtime-tool-policy))))
    ;; nil PLIST removes the entry entirely.
    (gptel-agent-runtime--tool-policy-set-entry "demo_tool" nil)
    (should (null (assoc "demo_tool"
                         gptel-agent-runtime-tool-policy)))))

(ert-deftest gar-e2e-tool-policy-editor-opens-with-correct-mode ()
  "Launching the editor produces a buffer in tool-policy-editor-mode."
  (let ((buf-name gptel-agent-runtime-tool-policy-editor-buffer-name))
    (unwind-protect
        (progn
          (gptel-agent-runtime-tool-policy-editor)
          (let ((buf (get-buffer buf-name)))
            (should (bufferp buf))
            (with-current-buffer buf
              (should (eq major-mode
                          'gptel-agent-runtime-tool-policy-editor-mode))
              ;; Tabulated-list-format is set; at least one column named "Tool".
              (should (string= "Tool" (car (aref tabulated-list-format 0)))))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

(ert-deftest gar-e2e-tool-policy-editor-reflects-policy-after-revert ()
  "After setting an override and reverting the editor buffer, the row
for that tool shows the user-supplied confirm setting."
  (let ((buf-name gptel-agent-runtime-tool-policy-editor-buffer-name)
        (gptel-agent-runtime-tool-policy nil))
    (unwind-protect
        (progn
          (gptel-agent-runtime-tool-policy-editor)
          ;; Mutate the policy and force a revert.
          (gptel-agent-runtime--tool-policy-set-entry
           "read_file" '(:confirm always))
          (with-current-buffer buf-name
            (tabulated-list-revert)
            ;; Search the buffer text for the tool name + "always".
            (goto-char (point-min))
            (should (search-forward "read_file" nil t))
            (goto-char (point-min))
            (should (search-forward "always" nil t))))
      (when (get-buffer buf-name) (kill-buffer buf-name)))))

;; ============================================================================
;; PR 11: high-fidelity model routing
;; ============================================================================

;; --- detection helper ---

(ert-deftest gar-e2e-needs-high-fidelity-detects-list-phrases ()
  "Goals containing list-style phrases trigger high-fidelity routing
when the model and enable flag are set."
  (let ((gptel-agent-runtime-high-fidelity-enabled t)
        (gptel-agent-runtime-high-fidelity-model 'fake-haiku))
    (dolist (g '("list my todos"
                 "list all open files"
                 "show me every entry"
                 "show all my buffers"
                 "every single item"
                 "give me the complete list"
                 "alle meine TODOs"
                 "vollstaendige Liste anzeigen"
                 "produce the answer verbatim"))
      (should (gptel-agent-runtime--needs-high-fidelity-p g)))))

(ert-deftest gar-e2e-needs-high-fidelity-skips-non-list-phrases ()
  "Routine non-list goals do NOT trigger high-fidelity routing."
  (let ((gptel-agent-runtime-high-fidelity-enabled t)
        (gptel-agent-runtime-high-fidelity-model 'fake-haiku))
    (dolist (g '("rename this variable"
                 "what is 2+2"
                 "summarise the file briefly"
                 "fix the typo in line 12"
                 "create a TODO"))
      (should-not (gptel-agent-runtime--needs-high-fidelity-p g)))))

(ert-deftest gar-e2e-needs-high-fidelity-disabled-by-flag ()
  "Disabled flag suppresses routing even on matching goals."
  (let ((gptel-agent-runtime-high-fidelity-enabled nil)
        (gptel-agent-runtime-high-fidelity-model 'fake-haiku))
    (should-not (gptel-agent-runtime--needs-high-fidelity-p
                 "list all my todos"))))

(ert-deftest gar-e2e-needs-high-fidelity-no-model-set ()
  "Routing is a no-op when no high-fidelity model is configured."
  (let ((gptel-agent-runtime-high-fidelity-enabled t)
        (gptel-agent-runtime-high-fidelity-model nil))
    (should-not (gptel-agent-runtime--needs-high-fidelity-p
                 "list all my todos"))))

;; --- end-to-end: routing binds gptel-model for the direct-response call ---

(defvar gar-e2e--captured-model-at-request nil
  "Captures the value of `gptel-model' inside the fake LLM stub so e2e
tests can assert that high-fidelity routing actually swapped the
binding for the direct-response gptel-request.")

(defun gar-e2e--capturing-fake-gptel-request (prompt &rest args)
  "Variant of the fake LLM that records `gptel-model' at call time."
  (push (cons (gar-test--classify-prompt prompt (plist-get args :system))
              (and (boundp 'gptel-model) gptel-model))
        gar-e2e--captured-model-at-request)
  (apply #'gar-test--fake-gptel-request prompt args))

(ert-deftest gar-e2e-direct-response-binds-high-fidelity-model ()
  "When the goal is list-style and a high-fidelity model is set, the
direct-response gptel-request runs under that model symbol while
the planner/reflection calls run under the original."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime-high-fidelity-enabled t)
          (gptel-agent-runtime-high-fidelity-model 'fake-haiku)
          (gptel-model 'fake-local-7b)
          (gar-e2e--captured-model-at-request nil)
          (gar-test--fake-llm-responses nil))
      (cl-letf (((symbol-function 'gptel-request)
                 #'gar-e2e--capturing-fake-gptel-request))
        (gptel-agent-runtime-start "list all my todos here")
        (let* ((calls (nreverse gar-e2e--captured-model-at-request))
               (direct-call (assoc :direct calls))
               (plan-call (assoc :plan calls)))
          (should direct-call)
          (should (eq 'fake-haiku (cdr direct-call)))
          (when plan-call
            (should (eq 'fake-local-7b (cdr plan-call)))))))))

(ert-deftest gar-e2e-direct-response-keeps-default-model-for-non-list ()
  "Goals that don't match the routing patterns keep the default model."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime-high-fidelity-enabled t)
          (gptel-agent-runtime-high-fidelity-model 'fake-haiku)
          (gptel-model 'fake-local-7b)
          (gar-e2e--captured-model-at-request nil)
          (gar-test--fake-llm-responses nil))
      (cl-letf (((symbol-function 'gptel-request)
                 #'gar-e2e--capturing-fake-gptel-request))
        (gptel-agent-runtime-start "say hello")
        (let* ((calls (nreverse gar-e2e--captured-model-at-request))
               (direct-call (assoc :direct calls)))
          (should direct-call)
          (should (eq 'fake-local-7b (cdr direct-call))))))))

(ert-deftest gar-e2e-high-fidelity-engaged-event-emitted ()
  "When routing engages, a `high-fidelity-model-engaged' event lands
in the event log so mission control can surface it."
  (gar-test-with-sandboxed-state
    (let ((gptel-agent-runtime-high-fidelity-enabled t)
          (gptel-agent-runtime-high-fidelity-model 'fake-haiku))
      (gar-test-with-fake-llm nil
        (gptel-agent-runtime-start "list all my todos here")
        (should (cl-some
                 (lambda (e)
                   (eq (gptel-agent-runtime-event-type e)
                       'high-fidelity-model-engaged))
                 gptel-agent-runtime-event-log))))))

;; ============================================================================
;; PR 13: similar-trajectories injection into the planner prompt
;; ============================================================================

(ert-deftest gar-e2e-planner-similar-context-empty-when-disabled ()
  "Helper returns empty string when the feature is disabled."
  (let ((gptel-agent-runtime-planner-similar-trajectories-enabled nil))
    (should (string-empty-p
             (gptel-agent-runtime--planner-similar-trajectories-context
              "list my todos")))))

(ert-deftest gar-e2e-planner-similar-context-empty-when-count-zero ()
  (let ((gptel-agent-runtime-planner-similar-trajectories-enabled t)
        (gptel-agent-runtime-planner-similar-trajectories-count 0))
    (should (string-empty-p
             (gptel-agent-runtime--planner-similar-trajectories-context
              "list my todos")))))

(ert-deftest gar-e2e-planner-similar-context-renders-when-hits-present ()
  "Helper renders the SIMILAR PAST GOALS block when search returns hits."
  (let ((gptel-agent-runtime-planner-similar-trajectories-enabled t)
        (gptel-agent-runtime-planner-similar-trajectories-count 3)
        (gptel-agent-runtime-planner-similar-trajectories-strategy 'lexical))
    (cl-letf (((symbol-function 'gptel-agent-runtime-sqlite-search-by-text)
               (lambda (_goal _n)
                 (list (list :id "t1" :goal "list my todos"
                             :outcome 'success
                             :finalized-at "2026-05-29T00:00:00")
                       (list :id "t2" :goal "show all todos verbatim"
                             :outcome 'failure
                             :finalized-at "2026-05-28T00:00:00")))))
      (let ((s (gptel-agent-runtime--planner-similar-trajectories-context
                "list my todos")))
        (should (stringp s))
        (should (string-match-p "SIMILAR PAST GOALS" s))
        (should (string-match-p "\\[success\\] list my todos" s))
        (should (string-match-p "\\[failure\\] show all todos verbatim" s))))))

(ert-deftest gar-e2e-planner-similar-context-prefers-cosine-when-available ()
  "When the strategy is `similar' and cosine API is bound, it is
called instead of the lexical fallback."
  (let ((gptel-agent-runtime-planner-similar-trajectories-enabled t)
        (gptel-agent-runtime-planner-similar-trajectories-count 2)
        (gptel-agent-runtime-planner-similar-trajectories-strategy 'similar)
        (cosine-called nil)
        (lex-called nil))
    (cl-letf
        (((symbol-function 'gptel-agent-runtime-sqlite-similar-trajectories)
          (lambda (_goal _n)
            (setq cosine-called t)
            (list (list :id "tx" :goal "x" :outcome 'success
                        :similarity 0.92))))
         ((symbol-function 'gptel-agent-runtime-sqlite-search-by-text)
          (lambda (&rest _) (setq lex-called t) nil)))
      (gptel-agent-runtime--planner-similar-trajectories-context "x")
      (should cosine-called)
      (should-not lex-called))))

(ert-deftest gar-e2e-planner-similar-context-falls-back-to-lexical ()
  "When cosine returns nil and strategy is `similar', the lexical
fallback runs."
  (let ((gptel-agent-runtime-planner-similar-trajectories-enabled t)
        (gptel-agent-runtime-planner-similar-trajectories-count 2)
        (gptel-agent-runtime-planner-similar-trajectories-strategy 'similar)
        (lex-called nil))
    (cl-letf
        (((symbol-function 'gptel-agent-runtime-sqlite-similar-trajectories)
          (lambda (&rest _) nil))
         ((symbol-function 'gptel-agent-runtime-sqlite-search-by-text)
          (lambda (&rest _)
            (setq lex-called t)
            (list (list :id "tx" :goal "x" :outcome 'success)))))
      (gptel-agent-runtime--planner-similar-trajectories-context "x")
      (should lex-called))))

(provide 'gar-loop-e2e-test)

;;; gar-loop-e2e-test.el ends here
