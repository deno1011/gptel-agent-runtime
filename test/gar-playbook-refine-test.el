;;; gar-playbook-refine-test.el --- ERT tests for gar-playbook-refine -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-refine-test--trajectory (id outcome playbook-id &optional verifier-reason)
  "Build a trajectory struct for testing."
  (let* ((failed-step
          (gptel-agent-runtime-trajectory-step-create
           :step-id "s1" :title "do thing"
           :suggested-tool "write_file"
           :args (list :path "/tmp/x")
           :risk 'write :attempts 1
           :status (if (eq outcome 'failure) 'failed 'done)))
         (verdict (when verifier-reason
                    (list :passed nil
                          :confidence 1.0
                          :reason verifier-reason
                          :suggested-correction "Try with /tmp/y instead"
                          :mode 'rule-based
                          :tool "write_file"))))
    (gptel-agent-runtime-trajectory-create
     :id id
     :goal "Write a config file"
     :session-id (concat "sess-" id)
     :started-at (format "2026-05-28T10:00:%02d" (random 60))
     :finalized-at (format "2026-05-28T10:01:%02d" (random 60))
     :outcome outcome
     :reason (if (eq outcome 'failure) 'failed 'done)
     :iteration-count 2
     :steps (list failed-step)
     :verifier-verdicts (if verdict (list verdict) '())
     :playbook-ids (list playbook-id)
     :reflections '()
     :decisions '())))

(defun gar-refine-test--playbook (id summary)
  "Build a playbook struct for testing."
  (gptel-agent-runtime-playbook-create
   :id id
   :summary summary
   :triggers (list "config" "file")
   :steps '((:title "Open file" :tool "write_file")
            (:title "Verify" :tool "read_file"))))

;; --- trajectories-for-playbook filter ---

(ert-deftest gar-refine-trajectories-for-playbook-filters-by-id ()
  "trajectories-for-playbook returns only trajectories matching the playbook id."
  (let* ((t1 (gar-refine-test--trajectory "1" 'failure "pb-a"))
         (t2 (gar-refine-test--trajectory "2" 'success "pb-b"))
         (t3 (gar-refine-test--trajectory "3" 'failure "pb-a"))
         (gptel-agent-runtime--trajectories (list t3 t2 t1))
         (hits (gptel-agent-runtime-trajectories-for-playbook "pb-a")))
    (should (= 2 (length hits)))
    (should (cl-every (lambda (t)
                        (member "pb-a"
                                (gptel-agent-runtime-trajectory-playbook-ids
                                 t)))
                      hits))))

;; --- consistent-failure heuristic ---

(ert-deftest gar-refine-failure-pattern-triggers-on-high-rate ()
  "failure-pattern fires when most recent runs are failures."
  (let* ((gptel-agent-runtime-refine-window 5)
         (gptel-agent-runtime-refine-min-runs 3)
         (gptel-agent-runtime-refine-failure-threshold 0.6)
         (gptel-agent-runtime--trajectories
          (list (gar-refine-test--trajectory "5" 'failure "pb" "boom")
                (gar-refine-test--trajectory "4" 'failure "pb" "boom")
                (gar-refine-test--trajectory "3" 'failure "pb" "boom")
                (gar-refine-test--trajectory "2" 'success "pb")
                (gar-refine-test--trajectory "1" 'success "pb")))
         (pattern (gptel-agent-runtime--refine-failure-pattern "pb")))
    (should pattern)
    (should (= 3 (plist-get pattern :failures)))
    (should (= 5 (plist-get pattern :window)))
    (should (>= (plist-get pattern :failure-rate) 0.6))
    (should (>= (length (plist-get pattern :evidence)) 1))))

(ert-deftest gar-refine-failure-pattern-nil-below-min-runs ()
  "Below min-runs the heuristic returns nil (insufficient data)."
  (let* ((gptel-agent-runtime-refine-min-runs 3)
         (gptel-agent-runtime--trajectories
          (list (gar-refine-test--trajectory "2" 'failure "pb" "boom")
                (gar-refine-test--trajectory "1" 'failure "pb" "boom"))))
    (should-not (gptel-agent-runtime--refine-failure-pattern "pb"))))

(ert-deftest gar-refine-failure-pattern-nil-below-threshold ()
  "When failure rate is below threshold the heuristic returns nil."
  (let* ((gptel-agent-runtime-refine-window 5)
         (gptel-agent-runtime-refine-min-runs 3)
         (gptel-agent-runtime-refine-failure-threshold 0.8)
         ;; 3 of 5 fail = 0.6, below 0.8 threshold.
         (gptel-agent-runtime--trajectories
          (list (gar-refine-test--trajectory "5" 'failure "pb" "boom")
                (gar-refine-test--trajectory "4" 'failure "pb" "boom")
                (gar-refine-test--trajectory "3" 'failure "pb" "boom")
                (gar-refine-test--trajectory "2" 'success "pb")
                (gar-refine-test--trajectory "1" 'success "pb"))))
    (should-not (gptel-agent-runtime--refine-failure-pattern "pb"))))

;; --- failure-evidence extraction ---

(ert-deftest gar-refine-collect-failure-evidence-from-failed-trajectory ()
  "Evidence extracts goal + step + verifier reason from a failed trajectory."
  (let* ((traj (gar-refine-test--trajectory "x" 'failure "pb"
                                            "Tool returned status=error"))
         (ev (gptel-agent-runtime--refine-collect-failure-evidence traj)))
    (should ev)
    (should (string= "Write a config file" (plist-get ev :goal)))
    (should (string= "do thing" (plist-get ev :step-title)))
    (should (string= "write_file" (plist-get ev :tool)))
    (should (string-match-p "status=error" (plist-get ev :reason)))))

(ert-deftest gar-refine-collect-evidence-nil-on-success-trajectory ()
  "Evidence is nil for successful trajectories (nothing to refine)."
  (let* ((traj (gar-refine-test--trajectory "x" 'success "pb")))
    (should-not (gptel-agent-runtime--refine-collect-failure-evidence traj))))

;; --- prompt building ---

(ert-deftest gar-refine-build-prompt-includes-playbook-and-evidence ()
  "The refinement prompt includes playbook id, summary, triggers, and failures."
  (let* ((pb (gar-refine-test--playbook "pb-test" "Write configs reliably"))
         (pattern (list :window 5 :failures 3 :failure-rate 0.6
                        :evidence
                        (list (list :goal "Write a config"
                                    :step-title "do thing"
                                    :tool "write_file"
                                    :reason "permission denied"
                                    :correction "use sudo path"
                                    :finalized-at "2026-05-28T10:00:00"))))
         (prompt (gptel-agent-runtime--refine-build-prompt pb pattern)))
    (should (string-match-p "pb-test" prompt))
    (should (string-match-p "Write configs reliably" prompt))
    (should (string-match-p "permission denied" prompt))
    (should (string-match-p "use sudo path" prompt))
    (should (string-match-p "FAILURE PATTERN" prompt))))

;; --- JSON parse on model response ---

(ert-deftest gar-refine-parse-candidate-from-well-formed-json ()
  "Parser converts a clean JSON response into the candidate plist."
  (let* ((response
          "{ \"summary\": \"Write with verified permissions\",
             \"triggers\": [\"config\", \"file\", \"write\"],
             \"steps\": [
               { \"title\": \"Check write access\", \"tool\": \"read_file\" },
               { \"title\": \"Write the file\", \"tool\": \"write_file\" }
             ],
             \"rationale\": \"The previous version skipped the access check\" }")
         (pb (gar-refine-test--playbook "pb-test" "Write configs"))
         (pattern (list :failures 3 :window 5 :failure-rate 0.6 :evidence '()))
         (candidate (gptel-agent-runtime--refine-parse-candidate
                     response pb pattern)))
    (should candidate)
    (should (eq 'candidate (plist-get candidate :status)))
    (should (string= "Write with verified permissions"
                     (plist-get candidate :summary)))
    (should (equal '("config" "file" "write") (plist-get candidate :triggers)))
    (should (= 2 (length (plist-get candidate :steps))))
    (should (string-match-p "auto-refinement" (plist-get candidate :reason)))
    (should (member "pb-test" (plist-get candidate :source-playbooks)))))

(ert-deftest gar-refine-parse-candidate-returns-nil-on-garbage ()
  "Parser returns nil on input with no JSON object."
  (let ((pb (gar-refine-test--playbook "pb" "x"))
        (pattern (list :failures 1 :window 1 :failure-rate 1.0 :evidence '())))
    (should-not (gptel-agent-runtime--refine-parse-candidate
                 "no json here" pb pattern))))

(ert-deftest gar-refine-parse-candidate-returns-nil-without-summary ()
  "Parser refuses candidates missing the required summary field."
  (let* ((response "{ \"triggers\": [\"x\"], \"steps\": [] }")
         (pb (gar-refine-test--playbook "pb" "x"))
         (pattern (list :failures 1 :window 1 :failure-rate 1.0 :evidence '())))
    (should-not (gptel-agent-runtime--refine-parse-candidate
                 response pb pattern))))

;; --- cooldown semantics ---

(ert-deftest gar-refine-cooldown-suppresses-rapid-rerefinement ()
  "When a recent refinement is recorded within the cooldown window,
cooled-down-p returns t."
  (let* ((gptel-agent-runtime-refine-cooldown-trajectories 5)
         (gptel-agent-runtime--trajectories (make-list 7 'placeholder))
         (gptel-agent-runtime--refinement-history
          ;; Last refinement was when only 4 trajectories existed.
          '(("pb-a" :at "..." :candidate-id "candidate-1"
             :trajectory-count 4))))
    (should (gptel-agent-runtime--refine-cooled-down-p "pb-a"))))

(ert-deftest gar-refine-cooldown-allows-after-enough-trajectories ()
  "Once enough new trajectories accumulate, cooldown clears."
  (let* ((gptel-agent-runtime-refine-cooldown-trajectories 5)
         (gptel-agent-runtime--trajectories (make-list 20 'placeholder))
         (gptel-agent-runtime--refinement-history
          '(("pb-a" :at "..." :candidate-id "candidate-1"
             :trajectory-count 4))))
    (should-not (gptel-agent-runtime--refine-cooled-down-p "pb-a"))))

;; --- subscriber registered ---

(ert-deftest gar-refine-subscriber-registered ()
  "The auto-refine subscriber is wired to `trajectory-recorded' at load."
  (let ((subs (alist-get 'trajectory-recorded
                         gptel-agent-runtime--event-subscribers)))
    (should subs)
    (should (cl-some (lambda (h)
                       (eq h #'gptel-agent-runtime--maybe-auto-refine-on-trajectory))
                     subs))))

(provide 'gar-playbook-refine-test)

;;; gar-playbook-refine-test.el ends here
