;;; gar-skill-promote-test.el --- ERT tests for gar-skill-promote -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)
(require 'gar-test-fake-llm)

(defun gar-skill-promote-test--trajectory (goal outcome &optional steps)
  "Build a trajectory struct with GOAL, OUTCOME, and STEPS (list of
trajectory-step structs).  Defaults to a single direct_response step
when STEPS is nil."
  (gptel-agent-runtime-trajectory-create
   :id (format "test-%s" (substring (secure-hash 'md5 goal) 0 8))
   :goal goal
   :outcome outcome
   :finalized-at "2026-05-30T00:00:00"
   :steps (or steps
              (list (gptel-agent-runtime-trajectory-step-create
                     :title "Answer directly"
                     :suggested-tool "direct_response")))))

;; --- ID + trigger derivation ---

(ert-deftest gar-skill-promote-id-is-stable-and-slugified ()
  (let ((id (gptel-agent-runtime--skill-promote-derive-id
             "List my todos here")))
    (should (string= "auto-list-my-todos-here" id))
    (should (string= id
                     (gptel-agent-runtime--skill-promote-derive-id
                      "List my todos here")))))

(ert-deftest gar-skill-promote-id-handles-empty-and-special-chars ()
  (should (string-match-p "^auto-"
                          (gptel-agent-runtime--skill-promote-derive-id "")))
  (should (string= "auto-foo-bar"
                   (gptel-agent-runtime--skill-promote-derive-id
                    "  Foo!!! BAR  "))))

(ert-deftest gar-skill-promote-id-truncates-long-goals ()
  (let ((id (gptel-agent-runtime--skill-promote-derive-id
             (make-string 200 ?a))))
    (should (<= (length id) 45))))

(ert-deftest gar-skill-promote-triggers-strip-stopwords ()
  (let ((trigs (gptel-agent-runtime--skill-promote-derive-triggers
                "List all my open TODOs and habits")))
    (should (member "open" trigs))
    (should (member "todos" trigs))
    (should (member "habits" trigs))
    (should-not (member "all" trigs))
    (should-not (member "my" trigs))
    (should-not (member "and" trigs))))

;; --- step extraction ---

(ert-deftest gar-skill-promote-extracts-tool-steps ()
  (let* ((s1 (gptel-agent-runtime-trajectory-step-create
              :title "Read inbox" :suggested-tool "read_file"
              :args '(:path "/tmp/inbox.org")))
         (s2 (gptel-agent-runtime-trajectory-step-create
              :title "Render" :suggested-tool "direct_response"))
         (traj (gar-skill-promote-test--trajectory
                "demo" 'success (list s1 s2)))
         (extracted (gptel-agent-runtime--skill-promote-extract-steps traj)))
    (should (= 2 (length extracted)))
    (should (equal "read_file" (plist-get (car extracted) :tool)))
    (should (equal "direct_response" (plist-get (cadr extracted) :tool)))))

(ert-deftest gar-skill-promote-extract-skips-steps-without-tool ()
  (let* ((s1 (gptel-agent-runtime-trajectory-step-create
              :title "Pure thinking" :suggested-tool nil))
         (s2 (gptel-agent-runtime-trajectory-step-create
              :title "Render" :suggested-tool "direct_response"))
         (traj (gar-skill-promote-test--trajectory
                "demo" 'success (list s1 s2))))
    (should (= 1 (length
                  (gptel-agent-runtime--skill-promote-extract-steps traj))))))

;; --- cluster filter ---

(ert-deftest gar-skill-promote-filter-keeps-successes-above-threshold ()
  (let ((gptel-agent-runtime-skill-promote-similarity-threshold 0.7))
    (let ((cluster (gptel-agent-runtime--skill-promote-filter-cluster
                    (list (list :id "a" :outcome 'success :similarity 0.91)
                          (list :id "b" :outcome 'success :similarity 0.50)
                          (list :id "c" :outcome 'failure :similarity 0.95)
                          (list :id "d" :outcome 'success :similarity 0.71)
                          ;; No :similarity means lexical hit -- kept.
                          (list :id "e" :outcome 'success)))))
      (should (= 3 (length cluster)))
      (should (cl-find "a" cluster :key (lambda (h) (plist-get h :id))
                       :test #'equal))
      (should (cl-find "d" cluster :key (lambda (h) (plist-get h :id))
                       :test #'equal))
      (should (cl-find "e" cluster :key (lambda (h) (plist-get h :id))
                       :test #'equal))
      (should-not (cl-find "b" cluster :key (lambda (h) (plist-get h :id))
                           :test #'equal))
      (should-not (cl-find "c" cluster :key (lambda (h) (plist-get h :id))
                           :test #'equal)))))

;; --- synthesis ---

(ert-deftest gar-skill-promote-synthesize-returns-skill-plist ()
  (let* ((s1 (gptel-agent-runtime-trajectory-step-create
              :title "Read" :suggested-tool "read_file"
              :args '(:path "/tmp/x")))
         (traj (gar-skill-promote-test--trajectory
                "list my todos here" 'success (list s1)))
         (cluster (list (list :id "t1" :outcome 'success :similarity 0.91)
                        (list :id "t2" :outcome 'success :similarity 0.85)
                        (list :id "t3" :outcome 'success :similarity 0.72)))
         (skill (gptel-agent-runtime--skill-promote-synthesize traj cluster)))
    (should skill)
    (should (string= "auto-list-my-todos-here" (plist-get skill :id)))
    (should (= 1 (length (plist-get skill :steps))))
    (should (member "todos" (plist-get skill :triggers)))
    (let ((meta (plist-get skill :metadata)))
      (should (eq 'auto-synth (plist-get meta :source)))
      (should (eq 'proposed (plist-get meta :status)))
      (should (= 3 (plist-get meta :cluster-size))))))

(ert-deftest gar-skill-promote-synthesize-returns-nil-without-steps ()
  "When the trajectory has no extractable steps, synthesis returns nil."
  (let* ((traj (gar-skill-promote-test--trajectory
                "no steps" 'success
                (list (gptel-agent-runtime-trajectory-step-create
                       :title "Thought only" :suggested-tool nil)))))
    (should-not
     (gptel-agent-runtime--skill-promote-synthesize traj '()))))

;; --- cooldown ---

(ert-deftest gar-skill-promote-cooldown-blocks-re-promotion ()
  (let* ((gptel-agent-runtime-skill-promote-cooldown-trajectories 10)
         (gptel-agent-runtime--skill-promote-trajectory-count 100)
         (gptel-agent-runtime--skill-promote-recent-ids
          (list (cons "auto-list-my-todos-here" 95))))
    (should (gptel-agent-runtime--skill-promote-cooldown-active-p
             "list my todos here")))
  (let* ((gptel-agent-runtime-skill-promote-cooldown-trajectories 10)
         (gptel-agent-runtime--skill-promote-trajectory-count 200)
         (gptel-agent-runtime--skill-promote-recent-ids
          (list (cons "auto-list-my-todos-here" 95))))
    (should-not (gptel-agent-runtime--skill-promote-cooldown-active-p
                 "list my todos here"))))

;; --- end-to-end auto-write ---

(ert-deftest gar-skill-promote-auto-write-creates-markdown-candidate ()
  "When the cluster exceeds the threshold AND mode is auto, the
candidate is written to disk."
  (let* ((tmp-dir (make-temp-file "gar-skill-promote-test-" t))
         (gptel-agent-runtime-skills-directory tmp-dir)
         (gptel-agent-runtime-skill-promote-mode 'auto)
         (gptel-agent-runtime-skill-promote-min-successes 2)
         (gptel-agent-runtime-skill-promote-similarity-threshold 0.5)
         (gptel-agent-runtime--skill-promote-recent-ids nil)
         (gptel-agent-runtime--skill-promote-trajectory-count 0)
         (s1 (gptel-agent-runtime-trajectory-step-create
              :title "Read" :suggested-tool "read_file"))
         (traj (gar-skill-promote-test--trajectory
                "demo goal" 'success (list s1)))
         (gptel-agent-runtime--trajectories (list traj)))
    (unwind-protect
        (cl-letf
            (((symbol-function
               'gptel-agent-runtime-sqlite-similar-trajectories)
              (lambda (&rest _)
                (list (list :id "x1" :outcome 'success :similarity 0.91)
                      (list :id "x2" :outcome 'success :similarity 0.81)))))
          (let* ((payload (list :id (gptel-agent-runtime-trajectory-id traj)
                                :goal "demo goal"
                                :outcome 'success))
                 (event (gptel-agent-runtime-event-create
                         :type 'trajectory-recorded
                         :payload payload
                         :taint 'trusted
                         :created-at "2026-05-30T00:00:00")))
            (gptel-agent-runtime--skill-promote-on-trajectory event)
            (let* ((auto-dir (gptel-agent-runtime--skill-promote-directory))
                   (files (directory-files auto-dir t "\\.md\\'")))
              (should (= 1 (length files)))
              (let ((content (with-temp-buffer
                               (insert-file-contents (car files))
                               (buffer-string))))
                (should (string-match-p "auto-demo-goal" content))
                (should (string-match-p "Distilled from 2 similar"
                                         content))))))
      (when (file-directory-p tmp-dir)
        (delete-directory tmp-dir t)))))

;; --- mode=off short-circuits ---

(ert-deftest gar-skill-promote-mode-off-does-not-fire ()
  (let* ((gptel-agent-runtime-skill-promote-mode 'off)
         (called nil))
    (cl-letf (((symbol-function
                'gptel-agent-runtime--skill-promote-fetch-similar)
               (lambda (&rest _) (setq called t) nil)))
      (gptel-agent-runtime--skill-promote-on-trajectory
       (gptel-agent-runtime-event-create
        :type 'trajectory-recorded
        :payload (list :id "x" :goal "y" :outcome 'success)
        :taint 'trusted
        :created-at "2026-05-30T00:00:00")))
    (should-not called)))

;; ============================================================================
;; PR 16: review / approve / reject flow
;; ============================================================================

(defmacro gar-skill-promote-test--with-temp-skills (&rest body)
  "Run BODY with a fresh skills-directory layout in temp."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "gar-skill-promote-review-" t))
          (gptel-agent-runtime-skills-directory tmp)
          (auto-dir (expand-file-name "auto-synth/" tmp)))
     (make-directory auto-dir t)
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp)
         (delete-directory tmp t)))))

(defun gar-skill-promote-test--seed-candidate (id)
  "Write a tiny markdown skill candidate under auto-synth/ and return path."
  (let* ((auto-dir (gptel-agent-runtime--skill-promote-directory))
         (file (expand-file-name (format "%s.md" id) auto-dir))
         (skill (list :id id
                      :summary (format "Test candidate %s" id)
                      :triggers '("test")
                      :steps '((:title "Step 1"
                                :tool "direct_response")))))
    (gptel-agent-runtime-skill-to-file skill file)
    file))

(ert-deftest gar-skill-promote-review-rows-lists-candidates ()
  "Rows builder lists every .md file under auto-synth/ excluding
the rejected/ subdirectory."
  (gar-skill-promote-test--with-temp-skills
    (gar-skill-promote-test--seed-candidate "auto-one")
    (gar-skill-promote-test--seed-candidate "auto-two")
    ;; Seed a rejected file too -- it must NOT show up.
    (let ((rej-dir (gptel-agent-runtime--skill-promote-rejected-directory)))
      (with-temp-file (expand-file-name "auto-old.md" rej-dir)
        (insert "---\nid: auto-old\n---\n# old\n")))
    (let ((rows (gptel-agent-runtime--skill-promote-rows)))
      (should (= 2 (length rows))))))

(ert-deftest gar-skill-promote-reject-moves-to-rejected-dir ()
  (gar-skill-promote-test--with-temp-skills
    (let* ((file (gar-skill-promote-test--seed-candidate "auto-rejectme")))
      (cl-letf (((symbol-function 'gptel-agent-runtime--skill-promote-current-file)
                 (lambda () file)))
        (gptel-agent-runtime-skill-promote-reject))
      (should-not (file-exists-p file))
      (let ((rej (expand-file-name
                  "auto-rejectme.md"
                  (gptel-agent-runtime--skill-promote-rejected-directory))))
        (should (file-exists-p rej))))))

(ert-deftest gar-skill-promote-approve-moves-and-registers ()
  "Approve moves the file out of auto-synth and into the skills-dir
root AND registers a playbook with the same id."
  (gar-skill-promote-test--with-temp-skills
    (let* ((file (gar-skill-promote-test--seed-candidate "auto-keep"))
           (gptel-agent-runtime-playbook-registry nil))
      (cl-letf (((symbol-function 'gptel-agent-runtime--skill-promote-current-file)
                 (lambda () file)))
        (gptel-agent-runtime-skill-promote-approve))
      (should-not (file-exists-p file))
      (let ((moved (expand-file-name
                    "auto-keep.md"
                    gptel-agent-runtime-skills-directory)))
        (should (file-exists-p moved)))
      (let ((registered (cl-find "auto-keep"
                                  gptel-agent-runtime-playbook-registry
                                  :key #'gptel-agent-runtime-playbook-id
                                  :test #'equal)))
        (should registered)))))

(ert-deftest gar-skill-promote-review-mode-sets-tabulated-list-format ()
  (gar-skill-promote-test--with-temp-skills
    (let ((buf (get-buffer-create "*gar-skill-review-test*")))
      (unwind-protect
          (with-current-buffer buf
            (gptel-agent-runtime-skill-promote-review-mode)
            (should (vectorp tabulated-list-format))
            ;; PR 17 added the Type column for unified review of skill +
            ;; refinement candidates.
            (should (= 4 (length tabulated-list-format)))
            (should (string= "Type"
                             (car (aref tabulated-list-format 0))))
            (should (string= "Candidate id"
                             (car (aref tabulated-list-format 1)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; --- PR 17: unified review covers both skill + refinement candidates ---

(ert-deftest gar-skill-promote-rows-includes-refinement-candidates ()
  "When PR 3 refinement candidates exist alongside skill candidates,
the unified row builder lists both."
  (gar-skill-promote-test--with-temp-skills
    (gar-skill-promote-test--seed-candidate "auto-skill-one")
    ;; Seed a fake refinement candidate using the .el format that
    ;; gar-memory writes.
    (cl-letf* ((tmp-refines-dir (make-temp-file "gar-refines-" t))
               ((symbol-function 'gptel-agent-runtime--candidates-directory)
                (lambda () tmp-refines-dir)))
      (with-temp-file (expand-file-name "candidate-x.el" tmp-refines-dir)
        (prin1 (gptel-agent-runtime--state-header "test")
               (current-buffer))
        (insert "\n")
        (prin1 '(:id "candidate-x" :summary "refined"
                 :triggers ("a") :steps ((:title "s")))
               (current-buffer))
        (insert "\n"))
      (let ((rows (gptel-agent-runtime--skill-promote-rows)))
        (should (= 2 (length rows)))
        ;; Type column should distinguish skill vs refinement.
        (let ((types (mapcar (lambda (row) (aref (cadr row) 0)) rows)))
          (should (member "skill" types))
          (should (member "refinement" types))))
      (delete-directory tmp-refines-dir t))))

(ert-deftest gar-skill-promote-candidate-type-by-extension ()
  (should (eq 'skill (gptel-agent-runtime--skill-promote-candidate-type
                      "/tmp/x.md")))
  (should (eq 'refinement
              (gptel-agent-runtime--skill-promote-candidate-type
               "/tmp/y.el")))
  (should (eq 'unknown
              (gptel-agent-runtime--skill-promote-candidate-type
               "/tmp/z.txt"))))

(ert-deftest gar-skill-promote-approve-refinement-replaces-playbook ()
  "Approving a refinement candidate moves the file to promoted/ AND
replaces the existing playbook with the candidate body."
  (let* ((tmp-root (make-temp-file "gar-refines-promote-" t))
         (cand-file (expand-file-name "test-rf.el" tmp-root))
         (gptel-agent-runtime-playbook-registry
          (list (gptel-agent-runtime-playbook-create
                 :id "test-rf"
                 :summary "old summary"
                 :triggers '("old")
                 :steps '((:title "old"))
                 :success-count 5 :failure-count 5))))
    (cl-letf (((symbol-function 'gptel-agent-runtime--candidates-directory)
               (lambda () tmp-root))
              ((symbol-function 'gptel-agent-runtime--skill-promote-current-file)
               (lambda () cand-file)))
      (with-temp-file cand-file
        (prin1 (gptel-agent-runtime--state-header "test")
               (current-buffer))
        (insert "\n")
        (prin1 '(:id "test-rf" :summary "refined"
                 :triggers ("new") :steps ((:title "new step")))
               (current-buffer))
        (insert "\n"))
      (gptel-agent-runtime-skill-promote-approve)
      ;; Original .el moved out of candidates/ root.
      (should-not (file-exists-p cand-file))
      ;; And into candidates/promoted/.
      (should (file-exists-p
               (expand-file-name "promoted/test-rf.el" tmp-root)))
      ;; Registry now holds the refined version.
      (let ((pb (cl-find "test-rf" gptel-agent-runtime-playbook-registry
                         :key #'gptel-agent-runtime-playbook-id
                         :test #'equal)))
        (should pb)
        (should (string= "refined"
                         (gptel-agent-runtime-playbook-summary pb)))))
    (when (file-directory-p tmp-root) (delete-directory tmp-root t))))

;; ============================================================================
;; PR 19: trust lifecycle  -- proposed -> approved -> trusted
;; ============================================================================

(defmacro gar-skill-promote-test--with-clean-trust (&rest body)
  "Run BODY with a fresh empty trust registry + temp persistence file."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "gar-trust-" nil ".el"))
          (gptel-agent-runtime--skill-promote-trust-registry nil)
          (gptel-agent-runtime-skill-promote-trust-file tmp))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file tmp)))))

(ert-deftest gar-skill-promote-trust-mark-approved-sets-state ()
  "`--mark-approved' transitions an unknown id into `approved'."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-mark-approved "auto-x")
    (should (eq 'approved
                (gptel-agent-runtime--skill-promote-trust-state "auto-x")))
    ;; Counter starts at zero.
    (let ((entry (cdr (assoc "auto-x"
                              gptel-agent-runtime--skill-promote-trust-registry))))
      (should (= 0 (plist-get entry :invocations-since-approval))))))

(ert-deftest gar-skill-promote-trust-mark-approved-is-no-op-on-trusted ()
  "A trusted skill stays trusted -- the ratchet only moves forward."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-trust-entry-set
     "auto-x"
     (list :state 'trusted :approved-at "ts"
           :invocations-since-approval 5 :promoted-at "ts2"))
    (gptel-agent-runtime--skill-promote-mark-approved "auto-x")
    (should (eq 'trusted
                (gptel-agent-runtime--skill-promote-trust-state "auto-x")))))

(ert-deftest gar-skill-promote-trust-bump-promotes-at-threshold ()
  "After threshold successful invocations, the state becomes `trusted'."
  (gar-skill-promote-test--with-clean-trust
    (let ((gptel-agent-runtime-skill-promote-trust-threshold 3))
      (gptel-agent-runtime--skill-promote-mark-approved "auto-y")
      ;; Bumps 1 and 2 stay `approved'.
      (gptel-agent-runtime--skill-promote-bump-invocation "auto-y")
      (gptel-agent-runtime--skill-promote-bump-invocation "auto-y")
      (should (eq 'approved
                  (gptel-agent-runtime--skill-promote-trust-state "auto-y")))
      ;; The 3rd bump triggers the transition.
      (gptel-agent-runtime--skill-promote-bump-invocation "auto-y")
      (should (eq 'trusted
                  (gptel-agent-runtime--skill-promote-trust-state "auto-y"))))))

(ert-deftest gar-skill-promote-trust-bump-noop-without-approval ()
  "`--bump-invocation' on an unknown id is a no-op (trust counter
only progresses for explicitly-approved skills)."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-bump-invocation "auto-z")
    (should-not (assoc "auto-z"
                       gptel-agent-runtime--skill-promote-trust-registry))))

(ert-deftest gar-skill-promote-trust-persists-and-loads ()
  "Save + reload round-trips the trust registry through disk."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-mark-approved "auto-persist")
    (gptel-agent-runtime--skill-promote-bump-invocation "auto-persist")
    (gptel-agent-runtime--skill-promote-save-trust-registry)
    (setq gptel-agent-runtime--skill-promote-trust-registry nil)
    (gptel-agent-runtime--skill-promote-load-trust-registry)
    (let ((entry (cdr (assoc "auto-persist"
                              gptel-agent-runtime--skill-promote-trust-registry))))
      (should entry)
      (should (eq 'approved (plist-get entry :state)))
      (should (= 1 (plist-get entry :invocations-since-approval))))))

(ert-deftest gar-skill-promote-trust-bypass-skips-write-for-trusted ()
  "When `auto-bypass' is on and a trusted skill already covers a goal,
`--write-from-payload' returns nil without writing to disk."
  (gar-skill-promote-test--with-clean-trust
    (let* ((tmp-dir (make-temp-file "gar-skill-promote-bypass-" t))
           (gptel-agent-runtime-skills-directory tmp-dir)
           (gptel-agent-runtime-skill-promote-trust-auto-bypass t)
           (traj (gptel-agent-runtime-trajectory-create
                  :id "t1"
                  :goal "list my todos here"
                  :outcome 'success
                  :finalized-at "ts"
                  :steps (list (gptel-agent-runtime-trajectory-step-create
                                :title "answer"
                                :suggested-tool "direct_response"))))
           (gptel-agent-runtime--trajectories (list traj)))
      (unwind-protect
          (progn
            ;; The id derived from this goal is what the synth would
            ;; produce. Mark it trusted and confirm bypass.
            (let ((id (gptel-agent-runtime--skill-promote-derive-id
                       "list my todos here")))
              (gptel-agent-runtime--skill-promote-trust-entry-set
               id (list :state 'trusted
                        :approved-at "ts"
                        :invocations-since-approval 10
                        :promoted-at "ts2"))
              (let* ((payload (list :id (gptel-agent-runtime-trajectory-id traj)
                                    :goal "list my todos here"
                                    :outcome 'success))
                     (cluster (list (list :id "t1" :outcome 'success)
                                    (list :id "t2" :outcome 'success)))
                     (result
                      (gptel-agent-runtime--skill-promote-write-from-payload
                       payload cluster)))
                ;; Bypass should return nil and NOT write a file.
                (should-not result)
                (let* ((auto-dir (gptel-agent-runtime--skill-promote-directory))
                       (md-files (and (file-directory-p auto-dir)
                                      (directory-files auto-dir t "\\.md\\'"))))
                  (should (null md-files))))))
        (when (file-directory-p tmp-dir) (delete-directory tmp-dir t))))))

(ert-deftest gar-skill-promote-trust-status-command-creates-buffer ()
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-mark-approved "auto-show")
    (let ((buf-name "*gptel-agent-skill-promote-trust*"))
      (unwind-protect
          (progn
            (gptel-agent-runtime-skill-promote-trust-status)
            (let ((buf (get-buffer buf-name)))
              (should (bufferp buf))
              (with-current-buffer buf
                (should buffer-read-only)
                (should (string-match-p "auto-show"
                                         (buffer-string)))
                (should (string-match-p "state=approved"
                                         (buffer-string))))))
        (when (get-buffer buf-name) (kill-buffer buf-name))))))

;; ============================================================================
;; PR 20: transfer-trust auto-approval
;; ============================================================================

(ert-deftest gar-skill-promote-jaccard-overlap-detected ()
  "Two goals about the same task type share derived triggers, so
Jaccard is >0; two unrelated goals share none, so Jaccard is 0."
  (let ((sim-related (gptel-agent-runtime--skill-promote-jaccard-similarity
                      "list my todos here" "show all my todos"))
        (sim-unrelated (gptel-agent-runtime--skill-promote-jaccard-similarity
                        "list my todos here" "rename this variable")))
    (should (> sim-related 0.0))
    (should (= sim-unrelated 0.0))))

(ert-deftest gar-skill-promote-jaccard-identical-is-one ()
  (should (= 1.0 (gptel-agent-runtime--skill-promote-jaccard-similarity
                  "configure deadlines" "configure deadlines"))))

(ert-deftest gar-skill-promote-jaccard-empty-is-zero ()
  (should (= 0.0 (gptel-agent-runtime--skill-promote-jaccard-similarity
                  "" "the and to or"))))

(ert-deftest gar-skill-promote-similarity-uses-jaccard-without-embeddings ()
  "When `--ollama-embedding' returns nil (default config), the
similarity helper falls back to Jaccard."
  (cl-letf (((symbol-function 'gptel-agent-runtime--ollama-embedding)
             (lambda (_text) nil)))
    (let ((sim (gptel-agent-runtime--skill-promote-similarity
                "list my todos" "show all my todos")))
      (should (> sim 0.0))
      (should (<= sim 1.0)))))

(ert-deftest gar-skill-promote-trusted-matches-requires-trusted-state ()
  "Only `trusted' entries count; `approved' entries don't transfer."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-trust-entry-set
     "auto-related-1"
     (list :state 'trusted :approved-at "t"
           :invocations-since-approval 10 :promoted-at "t2"
           :source-goal "list my todos"))
    (gptel-agent-runtime--skill-promote-trust-entry-set
     "auto-related-2"
     (list :state 'approved :approved-at "t"
           :invocations-since-approval 1
           :source-goal "show my todos"))
    (let* ((gptel-agent-runtime-skill-promote-transfer-trust-threshold 0.3)
           (matches (gptel-agent-runtime--skill-promote-trusted-matches
                     "list all my todos")))
      ;; Only the trusted entry matches.
      (should (= 1 (length matches)))
      (should (equal "auto-related-1" (car (car matches)))))))

(ert-deftest gar-skill-promote-trusted-matches-skips-entries-without-source-goal ()
  "Old trust entries (pre-PR-20) without :source-goal are skipped."
  (gar-skill-promote-test--with-clean-trust
    (gptel-agent-runtime--skill-promote-trust-entry-set
     "legacy-trusted"
     (list :state 'trusted :approved-at "t"
           :invocations-since-approval 10 :promoted-at "t2"))
    (let ((matches (gptel-agent-runtime--skill-promote-trusted-matches
                    "anything at all")))
      (should (null matches)))))

(ert-deftest gar-skill-promote-transfer-applies-when-min-matches-reached ()
  (gar-skill-promote-test--with-clean-trust
    (let ((gptel-agent-runtime-skill-promote-transfer-trust-min-matches 2)
          (gptel-agent-runtime-skill-promote-transfer-trust-threshold 0.3))
      ;; Seed three trusted skills, all similar to the candidate.
      (dolist (entry '(("auto-todos-1" . "list my todos")
                       ("auto-todos-2" . "show all my todos")
                       ("auto-todos-3" . "give me the todos")))
        (gptel-agent-runtime--skill-promote-trust-entry-set
         (car entry)
         (list :state 'trusted
               :approved-at "t"
               :invocations-since-approval 10
               :promoted-at "t2"
               :source-goal (cdr entry))))
      (should
       (gptel-agent-runtime--skill-promote-transfer-trust-applies-p
        "list all of my todos here")))))

(ert-deftest gar-skill-promote-transfer-does-not-apply-below-min-matches ()
  (gar-skill-promote-test--with-clean-trust
    (let ((gptel-agent-runtime-skill-promote-transfer-trust-min-matches 2)
          (gptel-agent-runtime-skill-promote-transfer-trust-threshold 0.3))
      ;; Only one trusted skill -- below the min.
      (gptel-agent-runtime--skill-promote-trust-entry-set
       "auto-todos-1"
       (list :state 'trusted :approved-at "t"
             :invocations-since-approval 10 :promoted-at "t2"
             :source-goal "list my todos"))
      (should-not
       (gptel-agent-runtime--skill-promote-transfer-trust-applies-p
        "list all of my todos here")))))

(ert-deftest gar-skill-promote-transfer-disabled-flag-respected ()
  (gar-skill-promote-test--with-clean-trust
    (let ((gptel-agent-runtime-skill-promote-transfer-trust-enabled nil)
          (gptel-agent-runtime-skill-promote-transfer-trust-min-matches 1)
          (gptel-agent-runtime-skill-promote-transfer-trust-threshold 0.0))
      (gptel-agent-runtime--skill-promote-trust-entry-set
       "auto-any"
       (list :state 'trusted :approved-at "t"
             :invocations-since-approval 10 :promoted-at "t2"
             :source-goal "anything"))
      (should-not
       (gptel-agent-runtime--skill-promote-transfer-trust-applies-p
        "anything else")))))

(ert-deftest gar-skill-promote-transfer-auto-approve-registers-and-marks ()
  (gar-skill-promote-test--with-clean-trust
    (let ((gptel-agent-runtime-playbook-registry nil)
          (skill (list :id "auto-newcomer"
                       :summary "Distilled"
                       :triggers '("todos")
                       :steps '((:title "do it"))))
          (matches '(("auto-todos-1" . 0.85)
                     ("auto-todos-2" . 0.72))))
      (gptel-agent-runtime--skill-promote-auto-approve-via-transfer
       skill "list my todos" matches)
      ;; Now registered as a playbook.
      (should (cl-find "auto-newcomer"
                       gptel-agent-runtime-playbook-registry
                       :key #'gptel-agent-runtime-playbook-id
                       :test #'equal))
      ;; And the trust registry records it as approved via
      ;; transfer-trust, with the source goal stored for FURTHER
      ;; transfer-trust propagation.
      (let ((entry (cdr (assoc "auto-newcomer"
                                gptel-agent-runtime--skill-promote-trust-registry))))
        (should (eq 'approved (plist-get entry :state)))
        (should (eq 'transfer-trust (plist-get entry :via)))
        (should (string= "list my todos" (plist-get entry :source-goal)))))))

(ert-deftest gar-skill-promote-write-from-payload-transfer-skips-file-write ()
  "End-to-end: with enough trusted similar skills, the auto-synth
writer registers + auto-approves WITHOUT writing a candidate file."
  (gar-skill-promote-test--with-clean-trust
    (let* ((tmp-dir (make-temp-file "gar-skill-transfer-" t))
           (gptel-agent-runtime-skills-directory tmp-dir)
           (gptel-agent-runtime-skill-promote-transfer-trust-enabled t)
           (gptel-agent-runtime-skill-promote-transfer-trust-min-matches 2)
           (gptel-agent-runtime-skill-promote-transfer-trust-threshold 0.2)
           (gptel-agent-runtime-playbook-registry nil)
           (traj (gptel-agent-runtime-trajectory-create
                  :id "new-traj"
                  :goal "list all open todos verbatim"
                  :outcome 'success
                  :finalized-at "ts"
                  :steps (list (gptel-agent-runtime-trajectory-step-create
                                :title "answer"
                                :suggested-tool "direct_response"))))
           (gptel-agent-runtime--trajectories (list traj)))
      (unwind-protect
          (progn
            ;; Seed two trusted similar skills.
            (gptel-agent-runtime--skill-promote-trust-entry-set
             "auto-list-my-todos-here"
             (list :state 'trusted :approved-at "t"
                   :invocations-since-approval 10 :promoted-at "t2"
                   :source-goal "list my todos here"))
            (gptel-agent-runtime--skill-promote-trust-entry-set
             "auto-show-all-my-todos"
             (list :state 'trusted :approved-at "t"
                   :invocations-since-approval 10 :promoted-at "t2"
                   :source-goal "show all my todos"))
            (let ((result
                   (gptel-agent-runtime--skill-promote-write-from-payload
                    (list :id (gptel-agent-runtime-trajectory-id traj)
                          :goal "list all open todos verbatim"
                          :outcome 'success)
                    (list (list :id "x" :outcome 'success)
                          (list :id "y" :outcome 'success)))))
              ;; Returns nil (the transfer-trust branch returns nil) and
              ;; writes no candidate file.
              (should-not result)
              (let* ((auto-dir
                      (gptel-agent-runtime--skill-promote-directory))
                     (md-files
                      (and (file-directory-p auto-dir)
                           (directory-files auto-dir t "\\.md\\'"))))
                (should (null md-files)))
              ;; BUT the new skill IS registered as a playbook AND
              ;; marked approved-via-transfer.
              (let ((pb (cl-find "auto-list-all-open-todos-verbatim"
                                  gptel-agent-runtime-playbook-registry
                                  :key #'gptel-agent-runtime-playbook-id
                                  :test #'equal)))
                (should pb))
              (let ((entry
                     (cdr (assoc
                           "auto-list-all-open-todos-verbatim"
                           gptel-agent-runtime--skill-promote-trust-registry))))
                (should (eq 'approved (plist-get entry :state)))
                (should (eq 'transfer-trust (plist-get entry :via))))))
        (when (file-directory-p tmp-dir) (delete-directory tmp-dir t))))))

(provide 'gar-skill-promote-test)

;;; gar-skill-promote-test.el ends here
