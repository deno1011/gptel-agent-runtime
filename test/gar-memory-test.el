;;; gar-memory-test.el --- ERT tests for gar-memory -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- novelty scoring ---
;;
;; The score is "inverse of best Jaccard against past playbook summaries
;; blended with inverse trigger-coverage by registered playbooks." With no
;; playbooks both inverses are 1.0; with a matching summary, novelty drops.

(ert-deftest gar-memory-novelty-score-in-unit-interval ()
  "novelty-score always returns a number in [0.0, 1.0]."
  (let* ((gptel-agent-runtime-playbook-registry nil)
         (s (gptel-agent-runtime-novelty-score "anything goes here")))
    (should (numberp s))
    (should (and (>= s 0.0) (<= s 1.0)))))

(ert-deftest gar-memory-novelty-score-empty-registry-high ()
  "With no playbooks registered, novelty is at the high end."
  (let* ((gptel-agent-runtime-playbook-registry nil)
         (s (gptel-agent-runtime-novelty-score "ground truth alpha")))
    (should (> s 0.5))))

(ert-deftest gar-memory-novelty-score-matching-playbook-lowers-score ()
  "A playbook with an overlapping summary lowers novelty for matching text."
  (let* ((pb (gar-memory-test--playbook
              :id "pb-match"
              :summary "ground truth alpha beta gamma delta"
              :triggers '("alpha" "beta")))
         (gptel-agent-runtime-playbook-registry (list pb))
         (overlap "ground truth alpha beta gamma delta")
         (disjoint "mango papaya kiwi pineapple")
         (s-overlap (gptel-agent-runtime-novelty-score overlap))
         (s-disjoint (gptel-agent-runtime-novelty-score disjoint)))
    (should (< s-overlap s-disjoint))))

;; --- playbook success rate (coarse totals) ---

(defun gar-memory-test--playbook (&rest plist)
  "Build a playbook struct with PLIST overrides for testing."
  (apply #'gptel-agent-runtime-playbook-create
         (append plist
                 (list :id (or (plist-get plist :id) "pb-test")
                       :summary (or (plist-get plist :summary) "test")))))

(ert-deftest gar-memory-playbook-success-rate-from-counts ()
  "playbook-success-rate is success-count/(success+failure)."
  (let ((pb (gar-memory-test--playbook :success-count 3 :failure-count 1)))
    (should (= 0.75 (gptel-agent-runtime-playbook-success-rate pb)))))

(ert-deftest gar-memory-playbook-success-rate-zero-runs-nil ()
  "playbook-success-rate is nil when neither count has fired."
  (let ((pb (gar-memory-test--playbook :success-count 0 :failure-count 0)))
    (should-not (gptel-agent-runtime-playbook-success-rate pb))))

;; --- per-invocation log + rolling success rate ---

(ert-deftest gar-memory-record-playbook-invocation-appends-to-ring ()
  "record-playbook-invocation pushes onto --playbook-invocations newest-first."
  (let* ((gptel-agent-runtime--playbook-invocations nil)
         (gptel-agent-runtime-playbook-registry
          (list (gar-memory-test--playbook :id "pb-rec"))))
    (gptel-agent-runtime-record-playbook-invocation
     "pb-rec" "session-a" 'success :iteration-count 3)
    (gptel-agent-runtime-record-playbook-invocation
     "pb-rec" "session-b" 'failure :iteration-count 5)
    (should (= 2 (length gptel-agent-runtime--playbook-invocations)))
    ;; Newest first.
    (should (eq 'failure
                (plist-get (car gptel-agent-runtime--playbook-invocations)
                           :outcome)))))

(ert-deftest gar-memory-record-playbook-invocation-bumps-coarse-totals ()
  "Recording invocations bumps the playbook's success-count / failure-count."
  (let* ((pb (gar-memory-test--playbook :id "pb-bump"))
         (gptel-agent-runtime--playbook-invocations nil)
         (gptel-agent-runtime-playbook-registry (list pb)))
    (gptel-agent-runtime-record-playbook-invocation "pb-bump" "s" 'success)
    (gptel-agent-runtime-record-playbook-invocation "pb-bump" "s" 'success)
    (gptel-agent-runtime-record-playbook-invocation "pb-bump" "s" 'failure)
    (should (= 2 (gptel-agent-runtime-playbook-success-count pb)))
    (should (= 1 (gptel-agent-runtime-playbook-failure-count pb)))))

(ert-deftest gar-memory-recent-success-rate-uses-window ()
  "playbook-recent-success-rate computes rate over the most-recent N entries."
  (let* ((pb (gar-memory-test--playbook :id "pb-window"))
         (gptel-agent-runtime--playbook-invocations nil)
         (gptel-agent-runtime-playbook-registry (list pb))
         (gptel-agent-runtime-playbook-recent-window 4))
    ;; Record 5 invocations: 2 success, 3 failure (oldest is success).
    ;; Window=4 means the oldest success is dropped, so the rolling rate
    ;; is 1/4 = 0.25.
    (dolist (outcome '(success failure success failure failure))
      (gptel-agent-runtime-record-playbook-invocation
       "pb-window" "s" outcome))
    (let ((rate (gptel-agent-runtime-playbook-recent-success-rate pb)))
      (should rate)
      (should (= 0.25 rate)))))

(ert-deftest gar-memory-recent-success-rate-nil-when-no-invocations ()
  "Rolling rate is nil when the playbook has never been invoked."
  (let* ((pb (gar-memory-test--playbook :id "pb-empty"))
         (gptel-agent-runtime--playbook-invocations nil)
         (gptel-agent-runtime-playbook-registry (list pb)))
    (should-not (gptel-agent-runtime-playbook-recent-success-rate pb))))

;; --- session-finalize outcome mapping ---

(ert-deftest gar-memory-session-finalized-outcome-mapping ()
  "--session-finalized-outcome maps reasons to playbook outcomes."
  (should (eq 'success
              (gptel-agent-runtime--session-finalized-outcome 'done)))
  (should (eq 'success
              (gptel-agent-runtime--session-finalized-outcome 'completed)))
  (should (eq 'failure
              (gptel-agent-runtime--session-finalized-outcome 'failed)))
  (should (eq 'abandoned
              (gptel-agent-runtime--session-finalized-outcome 'max-iterations)))
  (should (eq 'abandoned
              (gptel-agent-runtime--session-finalized-outcome 'cancelled))))

;; --- ranking ---

(ert-deftest gar-memory-rank-playbooks-by-success-orders-descending ()
  "rank-playbooks-by-success returns playbooks sorted by all-time success rate."
  (let* ((a (gar-memory-test--playbook :id "lo"
                                       :success-count 1 :failure-count 9))
         (b (gar-memory-test--playbook :id "hi"
                                       :success-count 9 :failure-count 1))
         (c (gar-memory-test--playbook :id "mid"
                                       :success-count 5 :failure-count 5))
         (gptel-agent-runtime-playbook-registry (list a b c))
         (gptel-agent-runtime--playbook-invocations nil)
         (ranked (gptel-agent-runtime-rank-playbooks-by-success)))
    (should (equal '("hi" "mid" "lo")
                   (mapcar #'gptel-agent-runtime-playbook-id ranked)))))

(provide 'gar-memory-test)

;;; gar-memory-test.el ends here
