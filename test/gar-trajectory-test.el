;;; gar-trajectory-test.el --- ERT tests for gar-trajectory -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-trajectory-test--step (&rest plist)
  "Build a plan-step for testing."
  (apply #'gptel-agent-runtime-plan-step-create
         (append plist
                 (list :id (or (plist-get plist :id) "tstep")
                       :title (or (plist-get plist :title) "test step")
                       :risk (or (plist-get plist :risk) 'write)))))

(defun gar-trajectory-test--result (status &rest plist)
  "Build an action-result."
  (apply #'gptel-agent-runtime-action-result-create
         (append plist
                 (list :status status
                       :tool (or (plist-get plist :tool) "write_file")))))

(defun gar-trajectory-test--session-with-step (step)
  "Build a session containing a single STEP in its current task's plan."
  (let* ((plan (gptel-agent-runtime-plan-create :steps (list step)))
         (task (gptel-agent-runtime-task-create
                :id "task-1"
                :goal "Test goal: write a file"
                :notes plan))
         (session (gptel-agent-runtime-session-create
                   :id "sess-1"
                   :current-task task
                   :iteration 1
                   :decisions '("started")
                   :started-at "2026-05-28T00:00:00")))
    session))

;; --- snapshot builder ---

(ert-deftest gar-trajectory-snapshot-plan-step-copies-fields ()
  "snapshot-plan-step produces a frozen step with the same key fields."
  (let* ((result (gar-trajectory-test--result 'ok :output "Written: /tmp/x"))
         (step (gar-trajectory-test--step
                :id "s1" :title "write x" :rationale "needed"
                :suggested-tool "write_file"
                :args (list :path "/tmp/x")
                :risk 'write :attempts 1 :status 'done
                :result result))
         (snap (gptel-agent-runtime--snapshot-plan-step step)))
    (should (gptel-agent-runtime-trajectory-step-p snap))
    (should (equal "s1" (gptel-agent-runtime-trajectory-step-step-id snap)))
    (should (equal "write x" (gptel-agent-runtime-trajectory-step-title snap)))
    (should (eq 'write (gptel-agent-runtime-trajectory-step-risk snap)))
    (should (eq 'done (gptel-agent-runtime-trajectory-step-status snap)))
    (should (eq 'ok (gptel-agent-runtime-trajectory-step-result-status snap)))
    (should (string= "Written: /tmp/x"
                     (gptel-agent-runtime-trajectory-step-result-output snap)))))

(ert-deftest gar-trajectory-snapshot-truncates-long-output ()
  "Snapshot truncates outputs longer than the configured max."
  (let* ((gptel-agent-runtime-trajectories-output-max-chars 100)
         (long-output (make-string 500 ?x))
         (result (gar-trajectory-test--result 'ok :output long-output))
         (step (gar-trajectory-test--step :result result))
         (snap (gptel-agent-runtime--snapshot-plan-step step))
         (out (gptel-agent-runtime-trajectory-step-result-output snap)))
    (should (< (length out) (length long-output)))
    (should (string-match-p "truncated" out))))

;; --- trajectory-from-session ---

(ert-deftest gar-trajectory-from-session-captures-key-fields ()
  "trajectory-from-session yields a populated trajectory struct."
  (let* ((result (gar-trajectory-test--result 'ok :output "Written"))
         (step (gar-trajectory-test--step :status 'done :result result))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'done)))
    (should (gptel-agent-runtime-trajectory-p traj))
    (should (string-prefix-p "trajectory-sess-1"
                             (gptel-agent-runtime-trajectory-id traj)))
    (should (eq 'success (gptel-agent-runtime-trajectory-outcome traj)))
    (should (equal "Test goal: write a file"
                   (gptel-agent-runtime-trajectory-goal traj)))
    (should (= 1 (length (gptel-agent-runtime-trajectory-steps traj))))))

(ert-deftest gar-trajectory-from-session-failure-maps-outcome ()
  "A `failed' finalize reason maps to outcome=failure."
  (let* ((step (gar-trajectory-test--step :status 'failed))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'failed)))
    (should (eq 'failure (gptel-agent-runtime-trajectory-outcome traj)))))

;; --- verifier-verdicts window filtering ---

(ert-deftest gar-trajectory-verdicts-during-filters-by-iso-range ()
  "verdicts-during selects only entries whose timestamp is in [start,end]."
  (let* ((gptel-agent-runtime--last-verifier-verdicts
          ;; Ring is newest first.
          '(("2026-05-28T01:00:30" :passed nil :reason "after window")
            ("2026-05-28T01:00:15" :passed t :reason "in window 2")
            ("2026-05-28T01:00:10" :passed nil :reason "in window 1")
            ("2026-05-28T00:59:59" :passed t :reason "before window")))
         (in-window
          (gptel-agent-runtime--verifier-verdicts-during
           "2026-05-28T01:00:00" "2026-05-28T01:00:20")))
    (should (= 2 (length in-window)))
    (should (cl-every (lambda (v)
                        (member (plist-get v :reason)
                                '("in window 1" "in window 2")))
                      in-window))))

;; --- record + retrieve round-trip ---

(ert-deftest gar-trajectory-record-pushes-onto-ring ()
  "record-trajectory prepends to the in-memory ring."
  (let* ((gptel-agent-runtime--trajectories nil)
         (gptel-agent-runtime-trajectories-directory
          (expand-file-name (make-temp-name "gar-traj-test-")
                            temporary-file-directory))
         (step (gar-trajectory-test--step))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'done)))
    (unwind-protect
        (progn
          (gptel-agent-runtime-record-trajectory traj)
          (should (= 1 (length gptel-agent-runtime--trajectories)))
          (should (eq traj (car gptel-agent-runtime--trajectories))))
      (when (file-directory-p gptel-agent-runtime-trajectories-directory)
        (delete-directory gptel-agent-runtime-trajectories-directory t)))))

(ert-deftest gar-trajectory-record-persists-and-loads ()
  "record + load round-trips the trajectory through disk."
  (let* ((gptel-agent-runtime-trajectories-directory
          (expand-file-name (make-temp-name "gar-traj-test-")
                            temporary-file-directory))
         (gptel-agent-runtime--trajectories nil)
         (step (gar-trajectory-test--step))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'done)))
    (unwind-protect
        (progn
          (gptel-agent-runtime-record-trajectory traj)
          (setq gptel-agent-runtime--trajectories nil)
          (gptel-agent-runtime-load-trajectories)
          (should (= 1 (length gptel-agent-runtime--trajectories)))
          (let ((loaded (car gptel-agent-runtime--trajectories)))
            (should (gptel-agent-runtime-trajectory-p loaded))
            (should (equal (gptel-agent-runtime-trajectory-goal traj)
                           (gptel-agent-runtime-trajectory-goal loaded)))))
      (when (file-directory-p gptel-agent-runtime-trajectories-directory)
        (delete-directory gptel-agent-runtime-trajectories-directory t)))))

;; --- search by goal substring ---

(ert-deftest gar-trajectory-search-by-goal-substring ()
  "trajectories-for-goal returns matches by case-insensitive substring."
  (let* ((step (gar-trajectory-test--step))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'done))
         (gptel-agent-runtime--trajectories (list traj))
         (hits (gptel-agent-runtime-trajectories-for-goal "WRITE A FILE")))
    (should (= 1 (length hits)))
    (should (eq traj (car hits)))))

(ert-deftest gar-trajectory-search-empty-on-miss ()
  "trajectories-for-goal returns nil when no goal matches."
  (let* ((step (gar-trajectory-test--step))
         (session (gar-trajectory-test--session-with-step step))
         (gptel-agent-runtime-playbook-registry nil)
         (traj (gptel-agent-runtime-trajectory-from-session session 'done))
         (gptel-agent-runtime--trajectories (list traj)))
    (should (null (gptel-agent-runtime-trajectories-for-goal "no such goal")))))

;; --- subscriber installed ---

(ert-deftest gar-trajectory-subscriber-registered ()
  "The trajectory-recording subscriber is wired to session-finalized at load."
  (let ((subs (alist-get 'session-finalized gptel-agent-runtime--event-subscribers)))
    (should subs)
    (should (cl-some (lambda (h)
                       (eq h #'gptel-agent-runtime--record-trajectory-on-finalize))
                     subs))))

(provide 'gar-trajectory-test)

;;; gar-trajectory-test.el ends here
