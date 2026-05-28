;;; gar-memory-sqlite-test.el --- ERT tests for gar-memory-sqlite -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defmacro gar-sqlite-test--with-temp-db (&rest body)
  "Run BODY with a fresh temporary SQLite DB; clean up after."
  `(let* ((tmp (make-temp-file "gar-sqlite-test-" nil ".sqlite"))
          (gptel-agent-runtime-sqlite-file tmp)
          (gptel-agent-runtime-sqlite-enabled t)
          ;; Disable embedding writes for tests; we cover the encode/decode
          ;; pair separately.
          (gptel-agent-runtime-sqlite-embed-trajectories nil)
          (gptel-agent-runtime--sqlite-db nil))
     (unwind-protect
         (progn ,@body)
       (gptel-agent-runtime-sqlite-close)
       (ignore-errors (delete-file tmp)))))

;; --- availability gate ---

(ert-deftest gar-sqlite-available-p ()
  "Emacs 29.1+ ships SQLite; the test environment must satisfy this."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (should (gptel-agent-runtime--sqlite-available-p)))

;; --- schema lifecycle ---

(ert-deftest gar-sqlite-open-creates-schema ()
  "Opening the DB creates the trajectories + embeddings tables."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (let ((db (gptel-agent-runtime-sqlite-open)))
      (should db)
      ;; sqlite_master tells us which tables exist.
      (let ((tables (mapcar #'car
                            (sqlite-select db
                             "SELECT name FROM sqlite_master
                                WHERE type='table' ORDER BY name"))))
        (should (member "trajectories" tables))
        (should (member "embeddings" tables))))))

;; --- vec encode / decode round-trip ---

(ert-deftest gar-sqlite-vec-round-trip ()
  "Encoding then decoding a vector preserves the values."
  (let* ((vec '(0.1 0.2 0.3 -0.5))
         (s (gptel-agent-runtime--sqlite-vec-to-string vec))
         (decoded (gptel-agent-runtime--sqlite-vec-from-string s)))
    (should (= (length vec) (length decoded)))
    (cl-loop for a in vec for b in decoded
             do (should (< (abs (- a b)) 0.0001)))))

(ert-deftest gar-sqlite-vec-from-string-handles-empty ()
  (should-not (gptel-agent-runtime--sqlite-vec-from-string nil))
  (should-not (gptel-agent-runtime--sqlite-vec-from-string "")))

;; --- insert + retrieve trajectory round-trip ---

(defun gar-sqlite-test--make-trajectory (id goal outcome)
  "Build a minimal trajectory for testing."
  (gptel-agent-runtime-trajectory-create
   :id id
   :goal goal
   :session-id (concat "sess-" id)
   :started-at "2026-05-29T00:00:00"
   :finalized-at "2026-05-29T00:01:00"
   :outcome outcome
   :reason 'done
   :iteration-count 1
   :steps '()
   :verifier-verdicts '()
   :playbook-ids '()
   :reflections '()
   :decisions '("started" "finished")))

(ert-deftest gar-sqlite-insert-retrieve-trajectory ()
  "Insert + get-trajectory round-trips the full struct via the blob column."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (let* ((traj (gar-sqlite-test--make-trajectory "t1" "Write config" 'success))
           (inserted-id (gptel-agent-runtime-sqlite-insert-trajectory traj)))
      (should (equal "t1" inserted-id))
      (let ((roundtrip (gptel-agent-runtime-sqlite-get-trajectory "t1")))
        (should roundtrip)
        (should (gptel-agent-runtime-trajectory-p roundtrip))
        (should (equal "Write config"
                       (gptel-agent-runtime-trajectory-goal roundtrip)))
        (should (eq 'success
                    (gptel-agent-runtime-trajectory-outcome roundtrip)))))))

(ert-deftest gar-sqlite-insert-or-replace-overwrites ()
  "INSERT OR REPLACE: re-inserting the same id updates rather than duplicating."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (let* ((traj-v1 (gar-sqlite-test--make-trajectory "dup" "First goal" 'failure))
           (traj-v2 (gar-sqlite-test--make-trajectory "dup" "Refined goal" 'success)))
      (gptel-agent-runtime-sqlite-insert-trajectory traj-v1)
      (gptel-agent-runtime-sqlite-insert-trajectory traj-v2)
      (let* ((db (gptel-agent-runtime-sqlite-open))
             (cnt (caar (sqlite-select db
                         "SELECT COUNT(*) FROM trajectories WHERE id='dup'"))))
        (should (= 1 cnt)))
      ;; The retained row is v2.
      (let ((roundtrip (gptel-agent-runtime-sqlite-get-trajectory "dup")))
        (should (eq 'success
                    (gptel-agent-runtime-trajectory-outcome roundtrip)))
        (should (equal "Refined goal"
                       (gptel-agent-runtime-trajectory-goal roundtrip)))))))

;; --- text search (FTS5 or LIKE fallback) ---

(ert-deftest gar-sqlite-search-by-text-returns-matches ()
  "search-by-text returns trajectories whose goal matches the pattern."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (gptel-agent-runtime-sqlite-insert-trajectory
     (gar-sqlite-test--make-trajectory "a" "Write config file" 'success))
    (gptel-agent-runtime-sqlite-insert-trajectory
     (gar-sqlite-test--make-trajectory "b" "Read web page" 'success))
    (gptel-agent-runtime-sqlite-insert-trajectory
     (gar-sqlite-test--make-trajectory "c" "Write JSON config" 'failure))
    (let* ((hits (gptel-agent-runtime-sqlite-search-by-text "config" 10))
           (ids (mapcar (lambda (h) (plist-get h :id)) hits)))
      (should (member "a" ids))
      (should (member "c" ids))
      (should-not (member "b" ids)))))

(ert-deftest gar-sqlite-search-by-text-respects-limit ()
  "The LIMIT clause caps result count."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (dotimes (i 5)
      (gptel-agent-runtime-sqlite-insert-trajectory
       (gar-sqlite-test--make-trajectory
        (format "lim-%d" i)
        (format "Write file %d" i)
        'success)))
    (let ((hits (gptel-agent-runtime-sqlite-search-by-text "Write" 2)))
      (should (<= (length hits) 2)))))

;; --- stats ---

(ert-deftest gar-sqlite-stats-counts-trajectories ()
  "stats reports the trajectory + embedding row counts and file path."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (gptel-agent-runtime-sqlite-insert-trajectory
     (gar-sqlite-test--make-trajectory "s1" "stat 1" 'success))
    (gptel-agent-runtime-sqlite-insert-trajectory
     (gar-sqlite-test--make-trajectory "s2" "stat 2" 'success))
    (let ((stats (gptel-agent-runtime-sqlite-stats)))
      (should stats)
      (should (= 2 (plist-get stats :trajectories)))
      (should (= 0 (plist-get stats :embeddings)))
      (should (stringp (plist-get stats :file))))))

;; --- migration tool ---

(ert-deftest gar-sqlite-migrate-flat-files-indexes-ring ()
  "migrate-flat-files inserts every trajectory currently in the ring."
  (skip-unless (gptel-agent-runtime--sqlite-available-p))
  (gar-sqlite-test--with-temp-db
    (let ((gptel-agent-runtime--trajectories
           (list (gar-sqlite-test--make-trajectory "m1" "Migrate 1" 'success)
                 (gar-sqlite-test--make-trajectory "m2" "Migrate 2" 'failure))))
      ;; The function calls load-trajectories internally; stub it out so
      ;; it doesn't overwrite our in-memory ring with disk state.
      (cl-letf (((symbol-function 'gptel-agent-runtime-load-trajectories)
                 (lambda () (length gptel-agent-runtime--trajectories))))
        (should (= 2 (gptel-agent-runtime-sqlite-migrate-flat-files)))
        (should (= 2 (plist-get (gptel-agent-runtime-sqlite-stats) :trajectories)))))))

(provide 'gar-memory-sqlite-test)

;;; gar-memory-sqlite-test.el ends here
