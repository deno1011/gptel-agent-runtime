;;; gar-skill-promote.el --- trajectory-to-skill promotion -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Added 2026-05-30 as PR 15 of
;; the self-reflective / learning / memorising track.

;;; Commentary:

;; Watches session-finalized events. When a successful trajectory
;; matches N+ similar past successes (by cosine over embeddings or
;; lexical fallback), distills a reusable markdown skill into
;; skills-directory/auto-synth/ for human review.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gptel-agent-runtime--timestamp "gar-substrate" ())
(declare-function gptel-agent-runtime-emit-event "gptel-agent-runtime"
                  (type &rest args))
(declare-function gptel-agent-runtime-subscribe "gar-substrate"
                  (event-type handler))
(declare-function gptel-agent-runtime-event-payload "gar-substrate" (event))

;; gar-trajectory accessors
(declare-function gptel-agent-runtime-trajectory-p "gptel-agent-runtime" (obj))
(declare-function gptel-agent-runtime-trajectory-id
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-goal
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-outcome
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-steps
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-step-title
                  "gptel-agent-runtime" (step))
(declare-function gptel-agent-runtime-trajectory-step-suggested-tool
                  "gptel-agent-runtime" (step))
(declare-function gptel-agent-runtime-trajectory-step-args
                  "gptel-agent-runtime" (step))

;; gar-memory-sqlite similarity search
(declare-function gptel-agent-runtime-sqlite-similar-trajectories
                  "gar-memory-sqlite" (text &optional limit))
(declare-function gptel-agent-runtime-sqlite-search-by-text
                  "gar-memory-sqlite" (pattern &optional limit))

;; gar-skills-md writer + reader
(declare-function gptel-agent-runtime-skill-to-file
                  "gar-skills-md" (skill file))
(declare-function gptel-agent-runtime-skill-from-file
                  "gar-skills-md" (file))
(declare-function gptel-agent-runtime--skills-md-skill->playbook
                  "gar-skills-md" (skill))
(declare-function gptel-agent-runtime--skills-md-register-playbook
                  "gar-skills-md" (playbook))

;; gar-memory refinement-candidate reader/dir
(declare-function gptel-agent-runtime--candidates-directory
                  "gar-memory" ())
(declare-function gptel-agent-runtime--read-versioned
                  "gar-substrate" (file))

;; gar-core playbook struct
(declare-function gptel-agent-runtime-playbook-create
                  "gptel-agent-runtime" (&rest plist))
(declare-function gptel-agent-runtime-playbook-id
                  "gptel-agent-runtime" (playbook))

(defvar gptel-agent-runtime-skills-directory)
(defvar gptel-agent-runtime-playbook-registry)

(defcustom gptel-agent-runtime-skill-promote-mode 'auto
  "Operating mode for trajectory-to-skill promotion.

- `off':    no auto-promotion; the substrate stays read-only.
- `manual': cluster detection still runs and emits a
            `skill-promote-candidate' event, but no file is written
            -- you call `M-x gptel-agent-runtime-promote-candidate'
            to materialise.
- `auto':   detection runs AND the candidate gets written to
            `skills-directory/auto-synth/' as :status proposed.
            Files are never auto-registered as playbooks unless
            `skill-promote-auto-register' is also non-nil."
  :type '(choice (const :tag "Off" off)
                 (const :tag "Manual (event only)" manual)
                 (const :tag "Auto-write candidate" auto))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-skill-promote-min-successes 3
  "Cluster size threshold before a candidate skill is proposed.
The current trajectory counts toward this -- so the default 3 fires
on the third consecutive success of the same pattern."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-skill-promote-similarity-threshold 0.7
  "Minimum cosine similarity for a trajectory to count as `same
pattern' as the current one.  Only consulted when embeddings are
available; the lexical fallback path uses FTS5 keyword overlap and
ignores this defcustom."
  :type 'float
  :safe #'floatp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-skill-promote-search-window 50
  "Maximum number of past trajectories to pull from the index when
looking for the cluster.  Keeps the cosine scan bounded on very
large archives."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-skill-promote-cooldown-trajectories 10
  "Don't re-propose the same pattern until N new trajectories have
been recorded since its last proposal.  Prevents the same skill
from being written every time the user runs the underlying goal."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-skill-promote-auto-register nil
  "When non-nil, auto-proposed skills are also registered as
playbooks in `gptel-agent-runtime-playbook-registry' immediately.
Default is nil because the safe path is `propose, human reviews,
human approves'."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defvar gptel-agent-runtime--skill-promote-recent-ids nil
  "Recently-promoted skill ids -- alist (id . trajectory-count-at-promotion).
Used to enforce `skill-promote-cooldown-trajectories'.")

(defvar gptel-agent-runtime--skill-promote-trajectory-count 0
  "Running count of trajectories observed since this Emacs started.
Used to age `--skill-promote-recent-ids' for the cooldown.")

(defun gptel-agent-runtime--skill-promote-directory ()
  "Return (and create if needed) the auto-synth skills subdirectory."
  (let ((dir (expand-file-name
              "auto-synth/"
              (or (and (boundp 'gptel-agent-runtime-skills-directory)
                       gptel-agent-runtime-skills-directory)
                  (expand-file-name "skills/"
                                    user-emacs-directory)))))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--skill-promote-fetch-similar (goal)
  "Return up to `skill-promote-search-window' similar past trajectories
for GOAL.  Prefers cosine similarity, falls back to lexical search.
Each hit is a plist with at least `:id :goal :outcome' and (for
the cosine path) `:similarity'."
  (let ((n gptel-agent-runtime-skill-promote-search-window))
    (or (and (fboundp 'gptel-agent-runtime-sqlite-similar-trajectories)
             (gptel-agent-runtime-sqlite-similar-trajectories goal n))
        (and (fboundp 'gptel-agent-runtime-sqlite-search-by-text)
             (gptel-agent-runtime-sqlite-search-by-text goal n))
        nil)))

(defun gptel-agent-runtime--skill-promote-filter-cluster (hits)
  "Return the subset of HITS that count as `same pattern' successes.
- :outcome must be `success' (or `\"success\"' as stored).
- When `:similarity' is present, it must be >= the threshold."
  (let ((thr gptel-agent-runtime-skill-promote-similarity-threshold))
    (cl-remove-if-not
     (lambda (hit)
       (and (let ((out (plist-get hit :outcome)))
              (or (eq out 'success)
                  (and (stringp out) (string= "success" out))))
            (let ((sim (plist-get hit :similarity)))
              (or (null sim) (>= sim thr)))))
     hits)))

(defun gptel-agent-runtime--skill-promote-cooldown-active-p (goal)
  "Return non-nil when a skill for GOAL was promoted within the
last `skill-promote-cooldown-trajectories' new trajectories."
  (let* ((cool gptel-agent-runtime-skill-promote-cooldown-trajectories)
         (now gptel-agent-runtime--skill-promote-trajectory-count)
         (entry (assoc (gptel-agent-runtime--skill-promote-derive-id goal)
                       gptel-agent-runtime--skill-promote-recent-ids)))
    (and entry (< (- now (cdr entry)) cool))))

(defun gptel-agent-runtime--skill-promote-derive-id (goal)
  "Derive a stable skill id from GOAL.  Lowercases, replaces
non-alphanumerics with hyphens, truncates to 40 chars.  The same
goal text always produces the same id so re-promotion replaces
rather than duplicates."
  (let* ((stripped (downcase (or goal "")))
         (slug (replace-regexp-in-string "[^a-z0-9]+" "-" stripped))
         (slug (replace-regexp-in-string "^-+\\|-+$" "" slug))
         (slug (if (string-empty-p slug) "skill" slug))
         (slug (if (> (length slug) 40) (substring slug 0 40) slug)))
    (concat "auto-" slug)))

(defun gptel-agent-runtime--skill-promote-derive-triggers (goal)
  "Derive a small trigger list from GOAL by lowercasing and
splitting on non-alphanumerics, then dropping function words and
short tokens."
  (let* ((stopwords '("the" "a" "an" "and" "or" "of" "in" "on" "at"
                      "to" "for" "with" "by" "is" "are" "was" "were"
                      "be" "i" "me" "my" "you" "your" "it" "this"
                      "that" "these" "those" "do" "does" "did"
                      "have" "has" "had" "show" "list" "get" "set"
                      "from" "into" "as" "but" "not"
                      "all" "every" "any" "some" "here" "there"
                      "now" "then" "also" "just" "only" "can" "will"))
         (raw (split-string (downcase (or goal "")) "[^a-z0-9]+" t)))
    (cl-remove-if (lambda (w)
                    (or (< (length w) 3)
                        (member w stopwords)))
                  raw)))

(defun gptel-agent-runtime--skill-promote-extract-steps (trajectory)
  "Extract a step-plist list from TRAJECTORY's trajectory-steps so
the markdown skill writer can serialise them.  Skips steps with no
:suggested-tool.  Returns nil when there's nothing extractable."
  (let ((out nil))
    (dolist (step (or (gptel-agent-runtime-trajectory-steps trajectory) '()))
      (let ((title (gptel-agent-runtime-trajectory-step-title step))
            (tool (gptel-agent-runtime-trajectory-step-suggested-tool step))
            (args (gptel-agent-runtime-trajectory-step-args step)))
        (when (and tool (not (string-empty-p (or tool ""))))
          (push (list :title (or title "")
                      :tool tool
                      :args (or args nil)
                      :rationale "Distilled from a successful trajectory.")
                out))))
    (nreverse out)))

(defun gptel-agent-runtime--skill-promote-synthesize (trajectory cluster)
  "Build a skill plist from TRAJECTORY (the most-recent success in
the cluster) and CLUSTER (list of trajectory summary plists, may
include TRAJECTORY).  Returns a plist with :id :summary :triggers
:steps :metadata.  Returns nil when the trajectory has no
extractable steps."
  (let* ((goal (gptel-agent-runtime-trajectory-goal trajectory))
         (steps (gptel-agent-runtime--skill-promote-extract-steps
                 trajectory))
         (id (gptel-agent-runtime--skill-promote-derive-id goal))
         (cluster-ids (mapcar (lambda (h) (plist-get h :id)) cluster)))
    (when steps
      (list :id id
            :summary (format
                      "Distilled from %d similar successful sessions: %s"
                      (length cluster)
                      (or goal "<no goal>"))
            :triggers (gptel-agent-runtime--skill-promote-derive-triggers
                       goal)
            :steps steps
            :metadata (list :source 'auto-synth
                            :status 'proposed
                            :cluster-size (length cluster)
                            :source-trajectory-ids cluster-ids
                            :created-at
                            (gptel-agent-runtime--timestamp))))))

(defun gptel-agent-runtime--skill-promote-target-file (skill)
  "Return the .md path for SKILL inside the auto-synth subdirectory."
  (expand-file-name (format "%s.md" (plist-get skill :id))
                    (gptel-agent-runtime--skill-promote-directory)))

(defun gptel-agent-runtime--skill-promote-write (skill)
  "Persist SKILL to disk and return the path.  Records the id in
`--skill-promote-recent-ids' so the cooldown takes effect."
  (when (fboundp 'gptel-agent-runtime-skill-to-file)
    (let ((file (gptel-agent-runtime--skill-promote-target-file skill)))
      (gptel-agent-runtime-skill-to-file skill file)
      (setq gptel-agent-runtime--skill-promote-recent-ids
            (cons (cons (plist-get skill :id)
                        gptel-agent-runtime--skill-promote-trajectory-count)
                  (cl-remove (plist-get skill :id)
                             gptel-agent-runtime--skill-promote-recent-ids
                             :key #'car :test #'equal)))
      file)))

(defun gptel-agent-runtime--skill-promote-on-trajectory (event)
  "Subscriber for `trajectory-recorded' events.  Increments the
running trajectory count, then runs the promotion check.  Wrapped
in `condition-case' so a synthesis error never breaks the substrate."
  (cl-incf gptel-agent-runtime--skill-promote-trajectory-count)
  (when (and (not (eq gptel-agent-runtime-skill-promote-mode 'off))
             (fboundp 'gptel-agent-runtime-trajectory-p))
    (condition-case _err
        (let* ((payload (and event
                             (gptel-agent-runtime-event-payload event)))
               (id (plist-get payload :id))
               (outcome (plist-get payload :outcome))
               (goal (plist-get payload :goal)))
          (when (and id
                     (or (eq outcome 'success)
                         (and (stringp outcome)
                              (string= "success" outcome)))
                     goal
                     (not (gptel-agent-runtime--skill-promote-cooldown-active-p
                           goal)))
            (let* ((hits (gptel-agent-runtime--skill-promote-fetch-similar
                          goal))
                   (cluster (gptel-agent-runtime--skill-promote-filter-cluster
                             hits))
                   (n (length cluster)))
              (when (>= n
                        gptel-agent-runtime-skill-promote-min-successes)
                (gptel-agent-runtime-emit-event
                 'skill-promote-candidate
                 :source "skill-promote"
                 :payload (list :id (gptel-agent-runtime--skill-promote-derive-id
                                     goal)
                                :goal goal
                                :cluster-size n
                                :outcome outcome)
                 :taint 'trusted)
                (when (eq gptel-agent-runtime-skill-promote-mode 'auto)
                  (gptel-agent-runtime--skill-promote-write-from-payload
                   payload cluster))))))
      (error nil))))

(defun gptel-agent-runtime--skill-promote-write-from-payload (payload cluster)
  "Helper used by the subscriber when `mode' is `auto'.  Looks up the
in-memory trajectory by id (so we can read its real steps), synthesises,
and writes."
  (let* ((id (plist-get payload :id))
         (traj (and (boundp 'gptel-agent-runtime--trajectories)
                    (cl-find id gptel-agent-runtime--trajectories
                             :key #'gptel-agent-runtime-trajectory-id
                             :test #'equal))))
    (when traj
      (let ((skill (gptel-agent-runtime--skill-promote-synthesize
                    traj cluster)))
        (when skill
          (let ((file (gptel-agent-runtime--skill-promote-write skill)))
            (gptel-agent-runtime-emit-event
             'skill-promote-written
             :source "skill-promote"
             :payload (list :id (plist-get skill :id)
                            :file file
                            :cluster-size (length cluster))
             :taint 'trusted)
            file))))))

;; ---------------------------------------------------------------------------
;; Review / approve / reject flow (PR 16)
;; ---------------------------------------------------------------------------

(defcustom gptel-agent-runtime-skill-promote-review-buffer-name
  "*gptel-agent-skill-promote-review*"
  "Buffer name for the tabulated-list review of auto-synth candidates."
  :type 'string
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime--skill-promote-rejected-directory ()
  "Return (and create) the auto-synth/rejected/ subdirectory.
Rejected candidates move here so they're out of the active review
list but still recoverable for inspection."
  (let ((dir (expand-file-name
              "rejected/"
              (gptel-agent-runtime--skill-promote-directory))))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--skill-promote-candidate-files ()
  "Return the list of skill candidate file paths in the auto-synth directory.
Excludes the rejected/ subdirectory."
  (let ((dir (gptel-agent-runtime--skill-promote-directory)))
    (when (file-directory-p dir)
      (cl-remove-if
       (lambda (f) (file-directory-p f))
       (directory-files dir t "\\.md\\'")))))

(defun gptel-agent-runtime--skill-promote-refinement-candidate-files ()
  "Return the list of refinement candidate file paths (PR 3).
Comes from `gar-memory.--candidates-directory'.  Empty list when
gar-memory hasn't initialised the directory yet."
  (when (fboundp 'gptel-agent-runtime--candidates-directory)
    (let ((dir (ignore-errors
                 (gptel-agent-runtime--candidates-directory))))
      (when (and dir (file-directory-p dir))
        (cl-remove-if
         (lambda (f) (file-directory-p f))
         (directory-files dir t "\\.el\\'"))))))

(defun gptel-agent-runtime--skill-promote-candidate-type (file)
  "Classify a candidate FILE by extension.
Returns `skill' for .md auto-synth candidates and `refinement' for
.el playbook-refinement candidates."
  (cond
   ((string-suffix-p ".md" file) 'skill)
   ((string-suffix-p ".el" file) 'refinement)
   (t 'unknown)))

(defun gptel-agent-runtime--skill-promote-rows ()
  "Build `tabulated-list-entries' for the unified review buffer.
Lists BOTH skill candidates (PR 15) and refinement candidates (PR 3)
so a single keystroke (`a' approve / `r' reject) can act on either."
  (let* ((skills (gptel-agent-runtime--skill-promote-candidate-files))
         (refines (gptel-agent-runtime--skill-promote-refinement-candidate-files))
         (files (append (or skills '()) (or refines '()))))
    (mapcar
     (lambda (file)
       (let* ((name (file-name-base file))
              (type (gptel-agent-runtime--skill-promote-candidate-type file))
              (type-label (pcase type
                            ('skill "skill")
                            ('refinement "refinement")
                            (_ "?")))
              (mtime (format-time-string
                      "%Y-%m-%d %H:%M"
                      (file-attribute-modification-time
                       (file-attributes file))))
              (size-bytes (file-attribute-size (file-attributes file)))
              (size (cond ((< size-bytes 1024) (format "%d B" size-bytes))
                          ((< size-bytes 1048576)
                           (format "%.1f KB" (/ size-bytes 1024.0)))
                          (t (format "%.1f MB"
                                     (/ size-bytes 1048576.0))))))
         (list file (vector type-label name mtime size))))
     files)))

(defun gptel-agent-runtime--skill-promote-current-file ()
  "Return the candidate file path on the current line, or signal."
  (or (tabulated-list-get-id)
      (user-error "No candidate on this line")))

(defun gptel-agent-runtime--skill-promote-load-skill (file)
  "Read FILE as a Markdown skill and return the plist, or nil on error."
  (when (and (fboundp 'gptel-agent-runtime-skill-from-file)
             (file-exists-p file))
    (condition-case _err
        (gptel-agent-runtime-skill-from-file file)
      (error nil))))

(defun gptel-agent-runtime--skill-promote-load-refinement (file)
  "Read FILE as a refinement candidate plist (PR 3 format).
Returns the plist or nil on parse failure."
  (when (and (fboundp 'gptel-agent-runtime--read-versioned)
             (file-exists-p file))
    (condition-case _err
        (let* ((parsed (gptel-agent-runtime--read-versioned file))
               (rest (cdr parsed)))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char rest)
            (read (current-buffer))))
      (error nil))))

(defun gptel-agent-runtime--skill-promote-refinement-promoted-dir ()
  "Return (and create) the candidates/promoted/ subdir for
already-approved refinement candidates."
  (let ((dir (expand-file-name
              "promoted/"
              (gptel-agent-runtime--candidates-directory))))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--skill-promote-refinement-rejected-dir ()
  "Return (and create) the candidates/rejected/ subdir."
  (let ((dir (expand-file-name
              "rejected/"
              (gptel-agent-runtime--candidates-directory))))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--skill-promote-approve-skill (src)
  "Internal: approve a SKILL candidate at SRC."
  (let* ((skills-dir (or (and (boundp 'gptel-agent-runtime-skills-directory)
                              gptel-agent-runtime-skills-directory)
                         user-emacs-directory))
         (dst (expand-file-name (file-name-nondirectory src) skills-dir))
         (skill (gptel-agent-runtime--skill-promote-load-skill src)))
    (unless (file-directory-p skills-dir) (make-directory skills-dir t))
    (rename-file src dst t)
    (when (and skill
               (fboundp 'gptel-agent-runtime--skills-md-skill->playbook)
               (fboundp 'gptel-agent-runtime--skills-md-register-playbook))
      (gptel-agent-runtime--skills-md-register-playbook
       (gptel-agent-runtime--skills-md-skill->playbook skill)))
    (gptel-agent-runtime-emit-event
     'skill-promote-approved
     :source "skill-promote"
     :payload (list :type 'skill
                    :file dst
                    :id (and skill (plist-get skill :id)))
     :taint 'trusted)
    (format "skill -> %s" dst)))

(defun gptel-agent-runtime--skill-promote-approve-refinement (src)
  "Internal: approve a REFINEMENT candidate at SRC.
Replaces the original playbook in the registry with the candidate
body and moves the .el to candidates/promoted/."
  (let* ((candidate (gptel-agent-runtime--skill-promote-load-refinement src))
         (id (and candidate (plist-get candidate :id)))
         (dst (expand-file-name
               (file-name-nondirectory src)
               (gptel-agent-runtime--skill-promote-refinement-promoted-dir))))
    (when (and id
               (boundp 'gptel-agent-runtime-playbook-registry)
               (fboundp 'gptel-agent-runtime-playbook-create))
      (let ((pb (gptel-agent-runtime-playbook-create
                 :id id
                 :summary (or (plist-get candidate :summary) "")
                 :triggers (or (plist-get candidate :triggers) '())
                 :steps (or (plist-get candidate :steps) '())
                 :success-count 0
                 :failure-count 0
                 :updated-at (gptel-agent-runtime--timestamp))))
        (setq gptel-agent-runtime-playbook-registry
              (cons pb
                    (cl-remove id
                               gptel-agent-runtime-playbook-registry
                               :key #'gptel-agent-runtime-playbook-id
                               :test #'equal)))))
    (rename-file src dst t)
    (gptel-agent-runtime-emit-event
     'skill-promote-approved
     :source "skill-promote"
     :payload (list :type 'refinement
                    :file dst
                    :id id)
     :taint 'trusted)
    (format "refinement -> %s" dst)))

;;;###autoload
(defun gptel-agent-runtime-skill-promote-approve ()
  "Approve the candidate on the current line.

Dispatches by file type:
- .md (skill candidate) -- move into the active skills directory,
  register as a playbook via gar-skills-md.
- .el (refinement candidate) -- replace the matching playbook in
  the registry with the candidate body, move .el to
  candidates/promoted/."
  (interactive)
  (let* ((src (gptel-agent-runtime--skill-promote-current-file))
         (type (gptel-agent-runtime--skill-promote-candidate-type src))
         (result (pcase type
                   ('skill
                    (gptel-agent-runtime--skill-promote-approve-skill src))
                   ('refinement
                    (gptel-agent-runtime--skill-promote-approve-refinement src))
                   (_ (user-error "Unknown candidate type: %s" src)))))
    (when (derived-mode-p 'gptel-agent-runtime-skill-promote-review-mode)
      (tabulated-list-revert))
    (message "Approved %s: %s" type result)))

;;;###autoload
(defun gptel-agent-runtime-skill-promote-reject ()
  "Reject the candidate on the current line.
Moves the file into the type-specific rejected/ subdirectory.
Recoverable -- the file isn't deleted, just shelved."
  (interactive)
  (let* ((src (gptel-agent-runtime--skill-promote-current-file))
         (type (gptel-agent-runtime--skill-promote-candidate-type src))
         (rejected-dir
          (pcase type
            ('skill
             (gptel-agent-runtime--skill-promote-rejected-directory))
            ('refinement
             (gptel-agent-runtime--skill-promote-refinement-rejected-dir))
            (_ (user-error "Unknown candidate type: %s" src))))
         (dst (expand-file-name (file-name-nondirectory src) rejected-dir)))
    (rename-file src dst t)
    (gptel-agent-runtime-emit-event
     'skill-promote-rejected
     :source "skill-promote"
     :payload (list :type type :file dst)
     :taint 'trusted)
    (when (derived-mode-p 'gptel-agent-runtime-skill-promote-review-mode)
      (tabulated-list-revert))
    (message "Rejected %s: %s" type (file-name-base src))))

;;;###autoload
(defun gptel-agent-runtime-skill-promote-view ()
  "Open the candidate on the current line in a read-only view buffer."
  (interactive)
  (let ((src (gptel-agent-runtime--skill-promote-current-file)))
    (view-file src)))

(defvar gptel-agent-runtime-skill-promote-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'gptel-agent-runtime-skill-promote-approve)
    (define-key map (kbd "r") #'gptel-agent-runtime-skill-promote-reject)
    (define-key map (kbd "v") #'gptel-agent-runtime-skill-promote-view)
    (define-key map (kbd "RET") #'gptel-agent-runtime-skill-promote-view)
    map)
  "Keymap for `gptel-agent-runtime-skill-promote-review-mode'.")

(define-derived-mode gptel-agent-runtime-skill-promote-review-mode
  tabulated-list-mode "GAR-Skill-Promote"
  "Major mode for reviewing auto-synth skill candidates.

Key bindings (inherited from `tabulated-list-mode' plus this mode's):
  a    Approve current candidate -- move to skills/ + register as playbook.
  r    Reject current candidate -- move to skills/auto-synth/rejected/.
  v    View current candidate in a read-only buffer.
  RET  Same as v.
  g    Refresh.
  q    Quit."
  (setq tabulated-list-format
        [("Type"          11 t)
         ("Candidate id"  36 t)
         ("Last modified" 17 t)
         ("Size"          10 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries
        #'gptel-agent-runtime--skill-promote-rows)
  (tabulated-list-init-header))

;;;###autoload
(defun gptel-agent-runtime-skill-promote-review ()
  "Open the tabulated-list reviewer for auto-synth skill candidates."
  (interactive)
  (let ((buf (get-buffer-create
              gptel-agent-runtime-skill-promote-review-buffer-name)))
    (with-current-buffer buf
      (gptel-agent-runtime-skill-promote-review-mode)
      (tabulated-list-print))
    (pop-to-buffer buf)))

;;;###autoload
(defalias 'gptel-agent-runtime-list-auto-synth-skills
  #'gptel-agent-runtime-skill-promote-review
  "Backward-compatible alias for the review UI.")

(when (fboundp 'gptel-agent-runtime-subscribe)
  (gptel-agent-runtime-subscribe
   'trajectory-recorded
   #'gptel-agent-runtime--skill-promote-on-trajectory))

(provide 'gar-skill-promote)

;;; gar-skill-promote.el ends here
