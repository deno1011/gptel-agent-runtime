;;; gar-playbook-experiment-test.el --- ERT tests for gar-playbook-experiment -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-exp-test--experiment (&rest plist)
  "Build an experiment struct for testing."
  (apply #'gptel-agent-runtime-experiment-create
         (append plist
                 (list :id (or (plist-get plist :id) "exp-test")
                       :playbook-id (or (plist-get plist :playbook-id) "pb-A")
                       :candidate-id (or (plist-get plist :candidate-id) "cand-1")
                       :candidate-summary "refined summary"
                       :candidate-triggers '("a" "b")
                       :candidate-steps '((:title "t1") (:title "t2"))
                       :decision-threshold (or (plist-get plist :decision-threshold) 3)
                       :margin (or (plist-get plist :margin) 0.2)
                       :status (or (plist-get plist :status) 'running)
                       :original-successes (or (plist-get plist :original-successes) 0)
                       :original-failures (or (plist-get plist :original-failures) 0)
                       :candidate-successes (or (plist-get plist :candidate-successes) 0)
                       :candidate-failures (or (plist-get plist :candidate-failures) 0)
                       :started-at "2026-05-28T00:00:00"))))

;; --- arm picking is deterministic ---

(ert-deftest gar-exp-pick-arm-deterministic-for-session ()
  "Same (experiment-id, session-id) always returns the same arm."
  (let* ((exp (gar-exp-test--experiment :id "deterministic-test"))
         (arm-1 (gptel-agent-runtime--experiment-pick-arm exp "sess-1"))
         (arm-2 (gptel-agent-runtime--experiment-pick-arm exp "sess-1"))
         (arm-3 (gptel-agent-runtime--experiment-pick-arm exp "sess-1")))
    (should (eq arm-1 arm-2))
    (should (eq arm-2 arm-3))
    (should (memq arm-1 '(original candidate)))))

(ert-deftest gar-exp-pick-arm-different-sessions-vary ()
  "Different session ids tend to produce different arms (over enough samples)."
  (let* ((exp (gar-exp-test--experiment :id "variance-test"))
         (originals 0) (candidates 0))
    (dotimes (i 100)
      (pcase (gptel-agent-runtime--experiment-pick-arm
              exp (format "sess-%d" i))
        ('original (cl-incf originals))
        ('candidate (cl-incf candidates))))
    ;; Hash-based 50-50: expect roughly balanced over 100 samples.
    (should (> originals 25))
    (should (> candidates 25))))

;; --- fork-playbook substitutes body for candidate arm ---

(ert-deftest gar-exp-fork-candidate-arm-substitutes-body ()
  "fork with arm=candidate returns a playbook with the candidate body."
  (let* ((original (gptel-agent-runtime-playbook-create
                    :id "pb-A" :summary "original summary"
                    :triggers '("x") :steps '((:title "orig-step"))))
         (exp (gar-exp-test--experiment :playbook-id "pb-A"))
         (forked (gptel-agent-runtime--experiment-fork-playbook
                  original exp 'candidate)))
    (should (equal "pb-A" (gptel-agent-runtime-playbook-id forked)))
    (should (equal "refined summary"
                   (gptel-agent-runtime-playbook-summary forked)))
    (should (equal '("a" "b") (gptel-agent-runtime-playbook-triggers forked)))))

(ert-deftest gar-exp-fork-original-arm-returns-original ()
  "fork with arm=original returns the input playbook unchanged."
  (let* ((original (gptel-agent-runtime-playbook-create
                    :id "pb-A" :summary "original summary"))
         (exp (gar-exp-test--experiment :playbook-id "pb-A"))
         (forked (gptel-agent-runtime--experiment-fork-playbook
                  original exp 'original)))
    (should (eq forked original))))

;; --- bump-arm increments correctly ---

(ert-deftest gar-exp-bump-arm-original-success ()
  (let ((exp (gar-exp-test--experiment)))
    (gptel-agent-runtime--experiment-bump-arm exp 'original 'success)
    (should (= 1 (gptel-agent-runtime-experiment-original-successes exp)))
    (should (= 0 (gptel-agent-runtime-experiment-original-failures exp)))))

(ert-deftest gar-exp-bump-arm-candidate-failure ()
  (let ((exp (gar-exp-test--experiment)))
    (gptel-agent-runtime--experiment-bump-arm exp 'candidate 'failure)
    (should (= 1 (gptel-agent-runtime-experiment-candidate-failures exp)))
    (should (= 0 (gptel-agent-runtime-experiment-candidate-successes exp)))))

(ert-deftest gar-exp-bump-arm-skipped-outcome-is-noop ()
  "Outcomes other than success/failure (e.g. abandoned) don't change counts."
  (let ((exp (gar-exp-test--experiment)))
    (gptel-agent-runtime--experiment-bump-arm exp 'candidate 'abandoned)
    (should (= 0 (gptel-agent-runtime-experiment-candidate-successes exp)))
    (should (= 0 (gptel-agent-runtime-experiment-candidate-failures exp)))))

;; --- decision rule ---

(ert-deftest gar-exp-decision-nil-below-threshold ()
  (let ((exp (gar-exp-test--experiment
              :decision-threshold 5
              :original-successes 2 :original-failures 0
              :candidate-successes 2 :candidate-failures 0)))
    (should-not (gptel-agent-runtime--experiment-decision exp))))

(ert-deftest gar-exp-decision-promote-on-clear-win ()
  (let* ((exp (gar-exp-test--experiment
               :decision-threshold 3 :margin 0.2
               :original-successes 1 :original-failures 4       ; 20%
               :candidate-successes 5 :candidate-failures 0))   ; 100%
         (d (gptel-agent-runtime--experiment-decision exp)))
    (should d)
    (should (eq 'promote (plist-get d :decision)))
    (should (= 0.2 (plist-get d :original-rate)))
    (should (= 1.0 (plist-get d :candidate-rate)))))

(ert-deftest gar-exp-decision-rollback-on-clear-loss ()
  (let* ((exp (gar-exp-test--experiment
               :decision-threshold 3 :margin 0.2
               :original-successes 5 :original-failures 0       ; 100%
               :candidate-successes 1 :candidate-failures 4))   ; 20%
         (d (gptel-agent-runtime--experiment-decision exp)))
    (should d)
    (should (eq 'rollback (plist-get d :decision)))))

(ert-deftest gar-exp-decision-inconclusive-within-margin ()
  (let* ((exp (gar-exp-test--experiment
               :decision-threshold 3 :margin 0.3
               :original-successes 3 :original-failures 2       ; 60%
               :candidate-successes 4 :candidate-failures 1))   ; 80%
         (d (gptel-agent-runtime--experiment-decision exp)))
    (should d)
    (should (eq 'inconclusive (plist-get d :decision)))))

;; --- end-to-end: resolve-matches → record outcome → bump ---

(ert-deftest gar-exp-record-outcome-bumps-the-right-arm ()
  "After resolve assigns an arm, record-outcome credits that arm."
  (let* ((exp (gar-exp-test--experiment :playbook-id "pb-X"))
         (gptel-agent-runtime--experiments (list exp))
         (gptel-agent-runtime--session-arm-assignments
          '((("sess-1" . "pb-X") . candidate)))
         (gptel-agent-runtime-experiments-directory
          (expand-file-name (make-temp-name "gar-exp-test-")
                            temporary-file-directory))
         ;; Suppress auto-decide for this isolated test.
         (gptel-agent-runtime-experiment-auto-decide nil))
    (unwind-protect
        (progn
          (gptel-agent-runtime--experiment-record-outcome
           "pb-X" "sess-1" 'success)
          (should (= 1 (gptel-agent-runtime-experiment-candidate-successes exp)))
          (should (= 0 (gptel-agent-runtime-experiment-original-successes exp)))
          (should-not
           (assoc '("sess-1" . "pb-X")
                  gptel-agent-runtime--session-arm-assignments)))
      (when (file-directory-p gptel-agent-runtime-experiments-directory)
        (delete-directory gptel-agent-runtime-experiments-directory t)))))

;; --- persistence round-trip ---

(ert-deftest gar-exp-save-load-round-trip ()
  "save + load round-trips an experiment through disk."
  (let* ((gptel-agent-runtime-experiments-directory
          (expand-file-name (make-temp-name "gar-exp-rt-")
                            temporary-file-directory))
         (gptel-agent-runtime--experiments nil)
         (exp (gar-exp-test--experiment
               :id "rt-test"
               :original-successes 2 :original-failures 1)))
    (unwind-protect
        (progn
          (gptel-agent-runtime--save-experiment exp)
          (setq gptel-agent-runtime--experiments nil)
          (gptel-agent-runtime-load-experiments)
          (should (= 1 (length gptel-agent-runtime--experiments)))
          (let ((loaded (car gptel-agent-runtime--experiments)))
            (should (gptel-agent-runtime-experiment-p loaded))
            (should (= 2 (gptel-agent-runtime-experiment-original-successes
                          loaded)))))
      (when (file-directory-p gptel-agent-runtime-experiments-directory)
        (delete-directory gptel-agent-runtime-experiments-directory t)))))

;; --- subscriber registered ---

(ert-deftest gar-exp-subscriber-registered ()
  "The experiment-outcome subscriber is wired to session-finalized at load."
  (let ((subs (alist-get 'session-finalized
                         gptel-agent-runtime--event-subscribers)))
    (should subs)
    (should (cl-some
             (lambda (h)
               (eq h #'gptel-agent-runtime--record-experiment-outcome-on-finalize))
             subs))))

(provide 'gar-playbook-experiment-test)

;;; gar-playbook-experiment-test.el ends here
