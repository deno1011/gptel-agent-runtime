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

(provide 'gar-loop-e2e-test)

;;; gar-loop-e2e-test.el ends here
