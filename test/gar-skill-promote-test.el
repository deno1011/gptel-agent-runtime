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

(provide 'gar-skill-promote-test)

;;; gar-skill-promote-test.el ends here
