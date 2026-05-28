;;; gar-memory.el --- persisted memory, novelty, synthesis, hypothesis-test -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Extracted from the monolith
;; gptel-agent-runtime.org on 2026-05-27 as PR 6 of the module split.

;;; Commentary:

;; Owns the runtime's persisted-state layer: sessions on disk, the
;; embedding cache, the lexical-Jaccard novelty detector, the playbook
;; success-scoring helpers, the strategy-synthesis tick subscriber that
;; writes candidate playbooks for human review, and the hypothesis-test
;; evidence helpers.
;;
;; The playbook `cl-defstruct' and its registry / register / load /
;; save / match functions are still in the master's Agent and Skill
;; Registry section -- they will move with gar-agents in PR 9. This
;; module references playbook accessors via late binding (defun bodies
;; resolve symbols at call time, not at load time), so the order works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(declare-function gptel-agent-runtime-emit-event "gptel-agent-runtime"
                  (type &rest args))
(declare-function gptel-agent-runtime--shorten "gptel-agent-runtime"
                  (text &optional max))
(declare-function gptel-agent-runtime--state-header "gptel-agent-runtime"
                  (&optional written-by))
(declare-function gptel-agent-runtime--read-versioned "gptel-agent-runtime"
                  (file))
(declare-function gptel-agent-runtime--timestamp "gptel-agent-runtime" ())
(declare-function gptel-agent-runtime--trigger-matches-p
                  "gptel-agent-runtime" (trigger text))
(declare-function gptel-agent-runtime--tokenize-text
                  "gptel-agent-runtime" (text))
(declare-function gptel-agent-runtime-make-evidence
                  "gptel-agent-runtime" (text source-type source-id &rest plist))
(declare-function gptel-agent-runtime-event-payload "gptel-agent-runtime" (event))
(declare-function gptel-agent-runtime-event-session-id "gptel-agent-runtime" (event))
(declare-function gptel-agent-runtime-session-current-task "gptel-agent-runtime" (session))
(declare-function gptel-agent-runtime-session-iteration "gptel-agent-runtime" (session))
(declare-function gptel-agent-runtime-task-goal "gptel-agent-runtime" (task))
(defvar gptel-agent-runtime--current-session)
(declare-function gptel-agent-runtime-playbook-bump "gptel-agent-runtime"
                  (playbook outcome timestamp))
(declare-function gptel-agent-runtime-subscribe
                  "gptel-agent-runtime" (event-type handler))

(defvar gptel-agent-runtime-tick-counter)
(defvar gptel-agent-runtime-playbook-registry)
(declare-function gptel-agent-runtime-playbook-id "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-summary "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-triggers "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-steps "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-success-count "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-failure-count "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-playbook-updated-at "gptel-agent-runtime" (pb))
(declare-function gptel-agent-runtime-match-playbooks "gptel-agent-runtime" (text))

;; ===== Phase 4: novelty detection, strategy synthesis, hypothesis-test, =====
;; ===== playbook success scoring                                          =====

(defcustom gptel-agent-runtime-novelty-threshold 0.7
  "Novelty score (0.0-1.0) at or above which a task is treated as novel.
When `gptel-agent-runtime-novelty-score' returns >= this threshold, the
runtime emits a `novelty-detected' event so brainstorm-mode subscribers can
react. Default 0.7 means tasks must be clearly unlike past work to trigger."
  :type 'number
  :safe #'numberp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-novelty-min-tokens 3
  "Minimum number of significant tokens in a task before novelty is scored."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime--significant-tokens (text)
  "Return a deduplicated list of significant tokens for novelty scoring.
Drops short and very-common stop tokens to reduce noise."
  (let* ((tokens (and (stringp text)
                      (split-string (downcase text) "[^a-zA-Z0-9_-]+" t)))
         (stops '("the" "a" "an" "and" "or" "of" "to" "in" "on" "for" "with"
                  "is" "are" "be" "as" "by" "that" "this" "it" "at" "from"
                  "do" "did" "does" "have" "has" "had" "you" "i" "me" "we"
                  "they" "he" "she" "us" "our" "your" "their"
                  "der" "die" "das" "und" "oder" "in" "an" "auf" "mit" "ist"
                  "im" "am" "ein" "eine" "den" "des" "dem" "zu" "von")))
    (cl-remove-duplicates
     (cl-remove-if (lambda (tok)
                     (or (< (length tok) 3)
                         (member tok stops)))
                   tokens)
     :test #'equal)))

(defun gptel-agent-runtime--jaccard (a b)
  "Return the Jaccard similarity between token lists A and B (0.0-1.0)."
  (if (or (null a) (null b))
      0.0
    (let* ((set-a (cl-remove-duplicates a :test #'equal))
           (set-b (cl-remove-duplicates b :test #'equal))
           (intersect (cl-count-if (lambda (x) (member x set-b)) set-a))
           (union (length (cl-union set-a set-b :test #'equal))))
      (if (zerop union) 0.0
        (/ (float intersect) union)))))

(defun gptel-agent-runtime-novelty-score (text)
  "Return a 0.0-1.0 novelty score for TEXT against past sessions and playbooks.
Higher means more novel. The score is a deterministic blend of the inverse
of the best Jaccard similarity against past playbook summaries and the
inverse of trigger-coverage by registered playbooks. The function never
calls a model; it is safe to invoke synchronously inside the policy broker
or the chat router."
  (let* ((tokens (gptel-agent-runtime--significant-tokens text)))
    (cond
     ((< (length tokens) gptel-agent-runtime-novelty-min-tokens) 0.0)
     ((null gptel-agent-runtime-playbook-registry) 1.0)
     (t
      (let* ((best 0.0)
             (trigger-hits 0))
        (dolist (pb gptel-agent-runtime-playbook-registry)
          (let* ((summary (or (gptel-agent-runtime-playbook-summary pb) ""))
                 (pb-tokens (gptel-agent-runtime--significant-tokens summary))
                 (sim (gptel-agent-runtime--jaccard tokens pb-tokens)))
            (when (> sim best) (setq best sim)))
          (dolist (trig (gptel-agent-runtime-playbook-triggers pb))
            (when (and trig (gptel-agent-runtime--trigger-matches-p trig text))
              (cl-incf trigger-hits))))
        (let* ((sim-novelty (- 1.0 best))
               (trigger-novelty
                (cond ((>= trigger-hits 2) 0.0)
                      ((= trigger-hits 1) 0.3)
                      (t 0.7)))
               ;; Heavier weight on Jaccard since trigger matches are coarse.
               (score (+ (* 0.65 sim-novelty)
                         (* 0.35 trigger-novelty))))
          (max 0.0 (min 1.0 score))))))))

(defun gptel-agent-runtime-novel-task-p (text)
  "Return non-nil and emit `novelty-detected' when TEXT is novel.
The threshold is `gptel-agent-runtime-novelty-threshold'."
  (let ((score (gptel-agent-runtime-novelty-score text)))
    (when (>= score gptel-agent-runtime-novelty-threshold)
      (gptel-agent-runtime-emit-event
       'novelty-detected
       :source "novelty-detector"
       :payload (list :score score
                      :text (gptel-agent-runtime--shorten text 220))
       :taint 'trusted)
      score)))

;; ----- Playbook success scoring helpers -----

(defun gptel-agent-runtime-playbook-success-rate (playbook)
  "Return the success rate (0.0-1.0) for PLAYBOOK or nil when unused."
  (let* ((s (or (gptel-agent-runtime-playbook-success-count playbook) 0))
         (f (or (gptel-agent-runtime-playbook-failure-count playbook) 0))
         (total (+ s f)))
    (when (> total 0)
      (/ (float s) total))))

;; ----- Per-invocation playbook tracking -----
;;
;; Every time the autonomous loop finalizes a session, the subscriber
;; below records ONE invocation entry per playbook that matched the
;; session's goal at routing time. The entry captures the playbook ID,
;; session ID, ISO timestamp, outcome (success/failure/abandoned),
;; iteration count, and free-form notes. The log is persisted to
;; `~/.emacs.d/gptel-agent-runtime/playbook-invocations.el' with the
;; standard versioned-state header.
;;
;; The rolling-window helpers (`playbook-recent-success-rate',
;; `playbook-last-used-at') consult this log first and fall back to the
;; coarse `success-count' / `failure-count' totals on the playbook
;; struct itself.

(defcustom gptel-agent-runtime-playbook-invocations-max-memory 500
  "Maximum number of playbook invocations kept in memory."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-playbook-recent-window 10
  "Number of most-recent invocations consulted by the rolling success rate.
The per-invocation rolling rate is more responsive to recent failures
than the all-time `success-count' / `failure-count' totals on the
playbook struct."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defvar gptel-agent-runtime--playbook-invocations nil
  "In-memory list of recent playbook invocations, newest first.
Each entry is a plist with :id :playbook-id :session-id :outcome
:started-at :finished-at :iteration-count :notes.")

(defun gptel-agent-runtime--playbook-invocations-file ()
  "Return the absolute path of the playbook-invocations log."
  (expand-file-name
   "playbook-invocations.el"
   (expand-file-name "gptel-agent-runtime/" user-emacs-directory)))

(defun gptel-agent-runtime--save-playbook-invocations ()
  "Persist the in-memory invocation log to disk with the schema header."
  (let* ((file (gptel-agent-runtime--playbook-invocations-file))
         (dir (file-name-directory file)))
    (unless (file-directory-p dir) (make-directory dir t))
    (condition-case _err
        (with-temp-file file
          (let ((create-lockfiles nil)
                (print-length nil)
                (print-level nil))
            (prin1 (gptel-agent-runtime--state-header "playbook-invocations")
                   (current-buffer))
            (insert "\n")
            (prin1 gptel-agent-runtime--playbook-invocations (current-buffer))
            (insert "\n")))
      (file-error nil))))

(defun gptel-agent-runtime-load-playbook-invocations ()
  "Load the persisted invocation log, replacing the in-memory ring."
  (let* ((file (gptel-agent-runtime--playbook-invocations-file)))
    (when (file-exists-p file)
      (let ((parsed (gptel-agent-runtime--read-versioned file)))
        (when parsed
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (cdr parsed))
            (setq gptel-agent-runtime--playbook-invocations
                  (condition-case nil (read (current-buffer)) (error nil)))))))))

(cl-defun gptel-agent-runtime-record-playbook-invocation
    (playbook-id session-id outcome
                 &key started-at iteration-count notes)
  "Append one PLAYBOOK-ID invocation entry to the log.
OUTCOME is one of `success', `failure', `abandoned'. SESSION-ID,
STARTED-AT (ISO timestamp string), ITERATION-COUNT, and NOTES are
preserved verbatim. The matching playbook's `success-count' /
`failure-count' / `updated-at' slots are also bumped so older code
paths continue to see the totals. Returns the recorded plist."
  (let* ((now (gptel-agent-runtime--timestamp))
         (inv (list :id (format "inv-%s" (format-time-string "%Y%m%d%H%M%S%N"))
                    :playbook-id playbook-id
                    :session-id session-id
                    :outcome outcome
                    :started-at (or started-at now)
                    :finished-at now
                    :iteration-count iteration-count
                    :notes notes)))
    (push inv gptel-agent-runtime--playbook-invocations)
    (when (> (length gptel-agent-runtime--playbook-invocations)
             gptel-agent-runtime-playbook-invocations-max-memory)
      (setcdr (nthcdr (1- gptel-agent-runtime-playbook-invocations-max-memory)
                      gptel-agent-runtime--playbook-invocations)
              nil))
    ;; Bump the playbook's coarse totals so all-time rate stays useful.
    ;; `setf' on the playbook accessors lives in gar-agents (where the
    ;; struct is defined) so we delegate to the bump helper there. Calling
    ;; `setf' inline here would expand at gar-memory's load time, before
    ;; gar-agents has installed the struct's setter machinery.
    (when (and (boundp 'gptel-agent-runtime-playbook-registry)
               (fboundp 'gptel-agent-runtime-playbook-bump))
      (let ((pb (cl-find-if
                 (lambda (p)
                   (equal (gptel-agent-runtime-playbook-id p) playbook-id))
                 gptel-agent-runtime-playbook-registry)))
        (gptel-agent-runtime-playbook-bump pb outcome now)))
    (gptel-agent-runtime--save-playbook-invocations)
    (gptel-agent-runtime-emit-event
     'playbook-invocation-recorded
     :source "memory"
     :session-id session-id
     :payload (list :playbook-id playbook-id :outcome outcome
                    :iteration-count iteration-count)
     :taint 'trusted)
    inv))

(defun gptel-agent-runtime-playbook-invocations-for (playbook-id &optional limit)
  "Return invocation plists for PLAYBOOK-ID, newest first, capped at LIMIT."
  (let ((results
         (cl-loop for inv in gptel-agent-runtime--playbook-invocations
                  when (equal (plist-get inv :playbook-id) playbook-id)
                  collect inv)))
    (if (and limit (numberp limit))
        (cl-subseq results 0 (min limit (length results)))
      results)))

(defun gptel-agent-runtime-playbook-recent-success-rate (playbook)
  "Return rolling success rate for PLAYBOOK over the recent invocations.
The window is `gptel-agent-runtime-playbook-recent-window'. Returns
nil when no invocations have been recorded for this playbook yet, so
callers can fall back to the coarse total-based rate."
  (let* ((id (gptel-agent-runtime-playbook-id playbook))
         (window (max 1 gptel-agent-runtime-playbook-recent-window))
         (invs (gptel-agent-runtime-playbook-invocations-for id window)))
    (when invs
      (let ((successes (cl-count-if
                        (lambda (i) (eq (plist-get i :outcome) 'success))
                        invs)))
        (/ (float successes) (length invs))))))

(defun gptel-agent-runtime-playbook-last-used-at (playbook)
  "Return the timestamp of the most recent recorded invocation, or nil.
Falls back to the playbook struct's `updated-at' slot when no
invocations are on file."
  (let* ((id (gptel-agent-runtime-playbook-id playbook))
         (recent (car (gptel-agent-runtime-playbook-invocations-for id 1))))
    (or (and recent (plist-get recent :finished-at))
        (gptel-agent-runtime-playbook-updated-at playbook))))

(defun gptel-agent-runtime-rank-playbooks-by-success (&optional limit)
  "Return registered playbooks ordered by best success rate.
Prefers the rolling-window rate from per-invocation tracking; falls
back to the coarse all-time `success-count' / `failure-count' totals
on the playbook struct. Playbooks with no usage history sort last but
are included so unused candidates are still discoverable."
  (let* ((scored
          (mapcar
           (lambda (pb)
             (cons pb
                   (or (gptel-agent-runtime-playbook-recent-success-rate pb)
                       (gptel-agent-runtime-playbook-success-rate pb)
                       -1.0)))
           gptel-agent-runtime-playbook-registry))
         (sorted (sort scored (lambda (a b) (> (cdr a) (cdr b)))))
         (heads (mapcar #'car sorted)))
    (if limit (cl-subseq heads 0 (min limit (length heads))) heads)))

(defun gptel-agent-runtime-next-time-do-this-first (text)
  "Return a one-line hint about which playbook to try first for TEXT, or nil.
Reports the rolling-window rate when available."
  (let* ((matches (and (fboundp 'gptel-agent-runtime-match-playbooks)
                       (gptel-agent-runtime-match-playbooks text)))
         (best (car matches))
         (recent (and best
                      (gptel-agent-runtime-playbook-recent-success-rate best)))
         (rate (or recent
                   (and best (gptel-agent-runtime-playbook-success-rate best))))
         (total (or (length (and best
                                 (gptel-agent-runtime-playbook-invocations-for
                                  (gptel-agent-runtime-playbook-id best))))
                    0)))
    (when (and best rate (>= rate 0.5))
      (format
       "Next time, start with playbook `%s' (%.0f%% success on %d %s)."
       (or (gptel-agent-runtime-playbook-id best)
           (gptel-agent-runtime-playbook-summary best))
       (* 100 rate)
       (if recent total
         (+ (or (gptel-agent-runtime-playbook-success-count best) 0)
            (or (gptel-agent-runtime-playbook-failure-count best) 0)))
       (if recent "recent runs" "lifetime runs")))))

(defun gptel-agent-runtime--session-finalized-outcome (reason)
  "Map a `--finalize-task' REASON symbol to a playbook outcome symbol."
  (pcase reason
    ('done 'success)
    ('completed 'success)
    ('failed 'failure)
    ('max-iterations 'abandoned)
    ('cancelled 'abandoned)
    (_ (if (memq reason '(error abort)) 'failure 'abandoned))))

(defun gptel-agent-runtime--record-playbook-invocations-on-finalize (event)
  "Subscriber: at `session-finalized', record one invocation per matched playbook.
Reads the session's most recent route via `match-playbooks' against the
goal text, then records one invocation entry per matched playbook with
the session's outcome derived from the finalize REASON in the event
payload."
  (when (fboundp 'gptel-agent-runtime-match-playbooks)
    (let* ((payload (gptel-agent-runtime-event-payload event))
           (session-id (gptel-agent-runtime-event-session-id event))
           (reason (plist-get payload :reason))
           (outcome (gptel-agent-runtime--session-finalized-outcome reason))
           ;; The session struct is no longer in scope here, but the
           ;; finalize event carries the memory path which holds the
           ;; persisted session. Cheaper: re-read the most recent goal
           ;; via the current session if available.
           (session (and (boundp 'gptel-agent-runtime--current-session)
                         gptel-agent-runtime--current-session))
           (goal (and session
                      (let ((task (gptel-agent-runtime-session-current-task
                                   session)))
                        (and task (gptel-agent-runtime-task-goal task)))))
           (matched (and goal (gptel-agent-runtime-match-playbooks goal))))
      (when (and session-id matched)
        (dolist (pb matched)
          (gptel-agent-runtime-record-playbook-invocation
           (gptel-agent-runtime-playbook-id pb)
           session-id outcome
           :iteration-count (and session
                                 (gptel-agent-runtime-session-iteration
                                  session))))))))

;;;###autoload
(defun gptel-agent-runtime-show-playbook-history (&optional limit)
  "Open a buffer summarising the most recent playbook invocations.
LIMIT defaults to 50."
  (interactive "P")
  (let* ((limit (or (and (numberp limit) limit) 50))
         (entries (cl-subseq gptel-agent-runtime--playbook-invocations
                             0 (min limit
                                    (length
                                     gptel-agent-runtime--playbook-invocations))))
         (buf (get-buffer-create "*gptel-agent-playbook-history*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "gptel-agent-runtime playbook invocations\n"))
        (insert (format "Recent window: %d   Total in memory: %d\n\n"
                        gptel-agent-runtime-playbook-recent-window
                        (length gptel-agent-runtime--playbook-invocations)))
        (if (null entries)
            (insert "  (no invocations recorded yet)\n")
          (dolist (inv entries)
            (insert
             (format "  %s  %-10s  %s  it=%s  session=%s\n"
                     (or (plist-get inv :finished-at) "?")
                     (or (plist-get inv :outcome) "?")
                     (or (plist-get inv :playbook-id) "?")
                     (or (plist-get inv :iteration-count) "-")
                     (or (plist-get inv :session-id) "?")))))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)))

(gptel-agent-runtime-subscribe
 'session-finalized
 #'gptel-agent-runtime--record-playbook-invocations-on-finalize)

;; ----- Strategy synthesis: candidate playbooks -----

(defcustom gptel-agent-runtime-strategy-synthesis-enabled t
  "When non-nil, the runtime synthesizes candidate playbooks on idle ticks.
Candidate playbooks are saved to
`~/.emacs.d/gptel-agent-runtime/playbooks/candidates/' with `:status candidate'
and are NOT auto-applied. They become active only after the user reviews
them via `M-x gptel-agent-runtime-review-playbook-candidates'."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-strategy-synthesis-min-success 2
  "Minimum success-count required for a playbook to seed a candidate synthesis."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-strategy-synthesis-interval-ticks 20
  "Minimum substrate ticks between two strategy-synthesis runs."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defvar gptel-agent-runtime--last-synthesis-tick 0
  "Tick at which the last strategy-synthesis run produced a candidate.")

(defun gptel-agent-runtime--candidates-directory ()
  "Return the candidate-playbook directory, creating it as needed."
  (let ((dir (expand-file-name
              "gptel-agent-runtime/playbooks/candidates/"
              user-emacs-directory)))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--write-candidate-playbook (candidate)
  "Persist CANDIDATE plist to a new file under the candidates directory.
Returns the absolute path written."
  (let* ((id (or (plist-get candidate :id)
                 (format "candidate-%s-%s"
                         gptel-agent-runtime-tick-counter
                         (format-time-string "%H%M%S"))))
         (file (expand-file-name
                (concat id ".el")
                (gptel-agent-runtime--candidates-directory))))
    (with-temp-file file
      (let ((create-lockfiles nil))
        (prin1 (gptel-agent-runtime--state-header "strategy-synthesis")
               (current-buffer))
        (insert "\n")
        (prin1 (plist-put candidate :id id) (current-buffer))
        (insert "\n")))
    file))

;;;###autoload
(defun gptel-agent-runtime-synthesize-candidate-playbook (&optional reason)
  "Produce one candidate playbook from the top-2 successful playbooks.
This is deterministic (no model call): it picks the two highest-success-rate
playbooks, merges their triggers, concatenates their step summaries, and
writes the result as a candidate. Returns the candidate plist, or nil when
there are not enough successful playbooks to synthesize from."
  (interactive)
  (let* ((seeds (cl-remove-if-not
                 (lambda (pb)
                   (let ((s (or (gptel-agent-runtime-playbook-success-count pb)
                                0)))
                     (>= s gptel-agent-runtime-strategy-synthesis-min-success)))
                 (gptel-agent-runtime-rank-playbooks-by-success))))
    (when (>= (length seeds) 2)
      (let* ((a (nth 0 seeds))
             (b (nth 1 seeds))
             (triggers (cl-remove-duplicates
                        (append (gptel-agent-runtime-playbook-triggers a)
                                (gptel-agent-runtime-playbook-triggers b))
                        :test #'equal))
             (summary (format "Synthesized strategy combining %s + %s"
                              (or (gptel-agent-runtime-playbook-summary a) "?")
                              (or (gptel-agent-runtime-playbook-summary b) "?")))
             (steps (append (gptel-agent-runtime-playbook-steps a)
                            (gptel-agent-runtime-playbook-steps b)))
             (candidate (list :id (format "candidate-%s-%s"
                                          gptel-agent-runtime-tick-counter
                                          (format-time-string "%H%M%S"))
                              :status 'candidate
                              :summary summary
                              :triggers triggers
                              :steps steps
                              :source-playbooks
                              (list (gptel-agent-runtime-playbook-id a)
                                    (gptel-agent-runtime-playbook-id b))
                              :reason (or reason "tick-driven synthesis")
                              :created-at (gptel-agent-runtime--timestamp)))
             (file (gptel-agent-runtime--write-candidate-playbook candidate)))
        (setq gptel-agent-runtime--last-synthesis-tick
              gptel-agent-runtime-tick-counter)
        (gptel-agent-runtime-emit-event
         'memory-write
         :source "strategy-synthesis"
         :payload (list :candidate (plist-get candidate :id) :file file)
         :taint 'trusted)
        (when (called-interactively-p 'interactive)
          (message "gptel-agent-runtime: wrote candidate playbook %s" file))
        candidate))))

(defun gptel-agent-runtime--maybe-synthesize-on-tick (_event)
  "Tick-subscribed callback that occasionally synthesizes a candidate playbook."
  (when (and gptel-agent-runtime-strategy-synthesis-enabled
             gptel-agent-runtime--idle-pump-timer
             (>= (- gptel-agent-runtime-tick-counter
                    gptel-agent-runtime--last-synthesis-tick)
                 gptel-agent-runtime-strategy-synthesis-interval-ticks))
    (ignore-errors
      (gptel-agent-runtime-synthesize-candidate-playbook
       "idle-pump tick"))))

;; Register the synthesis subscriber once.
(gptel-agent-runtime-subscribe
 'tick #'gptel-agent-runtime--maybe-synthesize-on-tick)

(defun gptel-agent-runtime-list-playbook-candidates ()
  "Return the list of candidate playbook files."
  (when (file-directory-p (gptel-agent-runtime--candidates-directory))
    (directory-files (gptel-agent-runtime--candidates-directory) t "\\.el\\'")))

;;;###autoload
(defun gptel-agent-runtime-review-playbook-candidates ()
  "Open a buffer listing pending candidate playbooks for human review."
  (interactive)
  (let* ((files (gptel-agent-runtime-list-playbook-candidates)))
    (with-current-buffer (get-buffer-create "*gptel-agent-candidates*")
      (erase-buffer)
      (insert (format "gptel-agent-runtime playbook candidates\nDirectory: %s\nCount: %d\n\n"
                      (gptel-agent-runtime--candidates-directory)
                      (length files)))
      (if (null files)
          (insert "  (no candidates pending; synthesis runs on idle ticks)\n")
        (dolist (file files)
          (let* ((parsed (gptel-agent-runtime--read-versioned file))
                 (rest (cdr parsed))
                 (payload (with-temp-buffer
                            (insert-file-contents file)
                            (goto-char rest)
                            (condition-case nil (read (current-buffer)) (error nil)))))
            (insert (format "  %s\n    summary: %s\n    triggers: %s\n    sources: %s\n"
                            file
                            (or (plist-get payload :summary) "?")
                            (or (plist-get payload :triggers) '())
                            (or (plist-get payload :source-playbooks) '()))))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer "*gptel-agent-candidates*")))

;; ----- Hypothesis-test process mode (scaffold) -----

(defcustom gptel-agent-runtime-hypothesis-test-enabled t
  "When non-nil, planner may choose `hypothesis-test' as a process mode.
The mode produces a small experiment step that the executor runs and feeds
back as evidence with source-type `experiment'. Useful when the runtime is
uncertain about an environmental capability (does this URL respond, does
this Babel language work, does this file exist)."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime-make-experiment-evidence
    (description observed expected-predicate &optional agent)
  "Construct evidence of type `experiment'.
DESCRIPTION is what was tested. OBSERVED is the observed result string.
EXPECTED-PREDICATE is a one-line description of the expected outcome (e.g.
\"URL responds 200\"). AGENT is the agent that ran the experiment.

Taint defaults to `untrusted' for experiment evidence so downstream prompts
treat the observation as data, not as an instruction."
  (gptel-agent-runtime-make-evidence
   (format "EXPERIMENT: %s\nEXPECTED: %s\nOBSERVED: %s"
           (or description "")
           (or expected-predicate "")
           (or observed ""))
   'experiment
   (or description "experiment")
   :agent agent
   :taint 'untrusted))

(defun gptel-agent-runtime-evaluate-experiment (evidence predicate-fn)
  "Apply PREDICATE-FN to the OBSERVED field of EVIDENCE.
PREDICATE-FN takes the observed string and returns non-nil on success.
Returns a plist with :passed-p, :observed, :description."
  (let* ((text (gptel-agent-runtime-evidence-text evidence))
         (observed (and (stringp text)
                        (when (string-match "OBSERVED: \\(.*\\)\\'" text)
                          (match-string 1 text))))
         (passed (and observed (funcall predicate-fn observed))))
    (list :passed-p (and passed t)
          :observed observed
          :description (gptel-agent-runtime-evidence-source-id evidence))))

(defcustom gptel-agent-runtime-memory-format 'sexp
  "Storage format for future runtime memory files.
Only `sexp' is implemented at this stage because it is easy to inspect from
Emacs and safe to evolve while the data model is still changing."
  :type '(choice (const :tag "S-expression" sexp))
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime-memory-ensure-directory ()
  "Ensure `gptel-agent-runtime-memory-directory' exists and return it."
  (make-directory gptel-agent-runtime-memory-directory t)
  gptel-agent-runtime-memory-directory)

(defun gptel-agent-runtime-memory-session-path (session)
  "Return the memory file path for SESSION."
  (expand-file-name
   (concat (gptel-agent-runtime-session-id session) ".el")
   (gptel-agent-runtime-memory-ensure-directory)))

(defun gptel-agent-runtime--struct-to-data (object)
  "Convert known runtime struct OBJECT into printable data."
  (cond
   ((gptel-agent-runtime-task-p object)
    `(:type task
      :id ,(gptel-agent-runtime-task-id object)
      :title ,(gptel-agent-runtime-task-title object)
      :goal ,(gptel-agent-runtime-task-goal object)
      :status ,(gptel-agent-runtime-task-status object)
      :parent-id ,(gptel-agent-runtime-task-parent-id object)
      :children ,(gptel-agent-runtime-task-children object)
      :created-at ,(gptel-agent-runtime-task-created-at object)
      :updated-at ,(gptel-agent-runtime-task-updated-at object)
      :notes ,(gptel-agent-runtime--struct-to-data
               (gptel-agent-runtime-task-notes object))))
   ((gptel-agent-runtime-plan-p object)
    `(:type plan
      :id ,(gptel-agent-runtime-plan-id object)
      :task-id ,(gptel-agent-runtime-plan-task-id object)
      :status ,(gptel-agent-runtime-plan-status object)
      :steps ,(mapcar #'gptel-agent-runtime--struct-to-data
                      (gptel-agent-runtime-plan-steps object))
      :created-at ,(gptel-agent-runtime-plan-created-at object)
      :updated-at ,(gptel-agent-runtime-plan-updated-at object)))
   ((gptel-agent-runtime-plan-step-p object)
    `(:type plan-step
      :id ,(gptel-agent-runtime-plan-step-id object)
      :title ,(gptel-agent-runtime-plan-step-title object)
      :rationale ,(gptel-agent-runtime-plan-step-rationale object)
      :agent ,(gptel-agent-runtime-plan-step-agent object)
      :skills ,(gptel-agent-runtime-plan-step-skills object)
      :tool ,(gptel-agent-runtime-plan-step-suggested-tool object)
      :args ,(gptel-agent-runtime-plan-step-args object)
      :parallel-p ,(gptel-agent-runtime-plan-step-parallel-p object)
      :risk ,(gptel-agent-runtime-plan-step-risk object)
      :status ,(gptel-agent-runtime-plan-step-status object)
      :result ,(gptel-agent-runtime--struct-to-data
                (gptel-agent-runtime-plan-step-result object))
      :observations ,(gptel-agent-runtime-plan-step-observations object)
      :reflections ,(gptel-agent-runtime-plan-step-reflections object)
      :attempts ,(gptel-agent-runtime-plan-step-attempts object)))
   ((gptel-agent-runtime-action-result-p object)
    `(:type action-result
      :status ,(gptel-agent-runtime-action-result-status object)
      :tool ,(gptel-agent-runtime-action-result-tool object)
      :output ,(gptel-agent-runtime-action-result-output object)
      :error ,(gptel-agent-runtime-action-result-error object)
      :warnings ,(gptel-agent-runtime-action-result-warnings object)
      :changed-files ,(gptel-agent-runtime-action-result-changed-files object)
      :changed-buffers ,(gptel-agent-runtime-action-result-changed-buffers object)
      :reflection-needed-p ,(gptel-agent-runtime-action-result-reflection-needed-p object)
      :metadata ,(gptel-agent-runtime-action-result-metadata object)))
   ((gptel-agent-runtime-event-p object)
    (gptel-agent-runtime--event-to-data object))
   ((gptel-agent-runtime-policy-decision-p object)
    `(:type policy-decision
      :allowed-p ,(gptel-agent-runtime-policy-decision-allowed-p object)
      :confirmation-required-p ,(gptel-agent-runtime-policy-decision-confirmation-required-p object)
      :reason ,(gptel-agent-runtime-policy-decision-reason object)
      :policy ,(gptel-agent-runtime-policy-decision-policy object)
      :taint ,(gptel-agent-runtime-policy-decision-taint object)
      :metadata ,(gptel-agent-runtime-policy-decision-metadata object)))
   ((gptel-agent-runtime-worker-p object)
    `(:type worker
      :id ,(gptel-agent-runtime-worker-id object)
      :session-id ,(gptel-agent-runtime-worker-session-id object)
      :agent ,(gptel-agent-runtime-worker-agent object)
      :step-id ,(gptel-agent-runtime-worker-step-id object)
      :step-title ,(gptel-agent-runtime-worker-step-title object)
      :tool ,(gptel-agent-runtime-worker-tool object)
      :status ,(gptel-agent-runtime-worker-status object)
      :prompt ,(gptel-agent-runtime-worker-prompt object)
      :result ,(gptel-agent-runtime--struct-to-data
                (gptel-agent-runtime-worker-result object))
      :error ,(gptel-agent-runtime-worker-error object)
      :attempts ,(gptel-agent-runtime-worker-attempts object)
      :max-retries ,(gptel-agent-runtime-worker-max-retries object)
      :queued-at ,(gptel-agent-runtime-worker-queued-at object)
      :started-at ,(gptel-agent-runtime-worker-started-at object)
      :updated-at ,(gptel-agent-runtime-worker-updated-at object)))
   ((gptel-agent-runtime-organization-unit-p object)
    `(:type organization-unit
      :name ,(gptel-agent-runtime-organization-unit-name object)
      :purpose ,(gptel-agent-runtime-organization-unit-purpose object)
      :triggers ,(gptel-agent-runtime-organization-unit-triggers object)
      :agent-names ,(gptel-agent-runtime-organization-unit-agent-names object)
      :parent ,(gptel-agent-runtime-organization-unit-parent object)
      :escalation ,(gptel-agent-runtime-organization-unit-escalation object)
      :enabled-p ,(gptel-agent-runtime-organization-unit-enabled-p object)
      :metadata ,(gptel-agent-runtime-organization-unit-metadata object)))
   ((gptel-agent-runtime-playbook-p object)
    `(:type playbook
      :id ,(gptel-agent-runtime-playbook-id object)
      :summary ,(gptel-agent-runtime-playbook-summary object)
      :triggers ,(gptel-agent-runtime-playbook-triggers object)
      :agent ,(gptel-agent-runtime-playbook-agent object)
      :skills ,(gptel-agent-runtime-playbook-skills object)
      :steps ,(gptel-agent-runtime-playbook-steps object)
      :source-session ,(gptel-agent-runtime-playbook-source-session object)
      :success-count ,(gptel-agent-runtime-playbook-success-count object)
      :failure-count ,(gptel-agent-runtime-playbook-failure-count object)
      :created-at ,(gptel-agent-runtime-playbook-created-at object)
      :updated-at ,(gptel-agent-runtime-playbook-updated-at object)
      :metadata ,(gptel-agent-runtime-playbook-metadata object)))
   ((gptel-agent-runtime-session-p object)
    `(:type session
      :id ,(gptel-agent-runtime-session-id object)
      :role ,(gptel-agent-runtime-session-role object)
      :root-task ,(gptel-agent-runtime--struct-to-data
                   (gptel-agent-runtime-session-root-task object))
      :current-task ,(gptel-agent-runtime--struct-to-data
                      (gptel-agent-runtime-session-current-task object))
      :iteration ,(gptel-agent-runtime-session-iteration object)
      :observations ,(gptel-agent-runtime-session-observations object)
      :decisions ,(gptel-agent-runtime-session-decisions object)
      :tool-results ,(gptel-agent-runtime-session-tool-results object)
      :workers ,(mapcar #'gptel-agent-runtime--struct-to-data
                        (gptel-agent-runtime-session-workers object))
      :process ,(gptel-agent-runtime-session-process object)
      :started-at ,(gptel-agent-runtime-session-started-at object)
      :updated-at ,(gptel-agent-runtime-session-updated-at object)))
   (t object)))

(defun gptel-agent-runtime-memory-write-session (session)
  "Write SESSION to its memory file and return the file path."
  (let ((path (gptel-agent-runtime-memory-session-path session))
        (print-length nil)
        (print-level nil))
    (with-temp-file path
      (insert ";;; gptel-agent-runtime session memory -*- mode: emacs-lisp; -*-\n")
      (prin1 (gptel-agent-runtime--struct-to-data session) (current-buffer))
      (insert "\n"))
    path))

(defun gptel-agent-runtime--data-to-struct (data)
  "Convert persisted DATA back into runtime structs."
  (if (not (and (listp data) (keywordp (car data))))
      data
    (pcase (plist-get data :type)
      ('task
       (gptel-agent-runtime-task-create
        :id (plist-get data :id)
        :title (plist-get data :title)
        :goal (plist-get data :goal)
        :status (plist-get data :status)
        :parent-id (plist-get data :parent-id)
        :children (plist-get data :children)
        :created-at (plist-get data :created-at)
        :updated-at (plist-get data :updated-at)
        :notes (gptel-agent-runtime--data-to-struct
                (plist-get data :notes))))
      ('plan
       (gptel-agent-runtime-plan-create
        :id (plist-get data :id)
        :task-id (plist-get data :task-id)
        :status (plist-get data :status)
        :steps (mapcar #'gptel-agent-runtime--data-to-struct
                       (plist-get data :steps))
        :created-at (plist-get data :created-at)
        :updated-at (plist-get data :updated-at)))
      ('plan-step
       (gptel-agent-runtime-plan-step-create
        :id (plist-get data :id)
        :title (plist-get data :title)
        :rationale (plist-get data :rationale)
        :agent (plist-get data :agent)
        :skills (plist-get data :skills)
        :suggested-tool (plist-get data :tool)
        :args (plist-get data :args)
        :parallel-p (plist-get data :parallel-p)
        :risk (plist-get data :risk)
        :status (plist-get data :status)
        :result (gptel-agent-runtime--data-to-struct
                 (plist-get data :result))
        :observations (plist-get data :observations)
        :reflections (plist-get data :reflections)
        :attempts (plist-get data :attempts)))
      ('action-result
       (gptel-agent-runtime-action-result-create
        :status (plist-get data :status)
        :tool (plist-get data :tool)
        :output (plist-get data :output)
        :error (plist-get data :error)
        :warnings (plist-get data :warnings)
        :changed-files (plist-get data :changed-files)
        :changed-buffers (plist-get data :changed-buffers)
        :reflection-needed-p (plist-get data :reflection-needed-p)
        :metadata (plist-get data :metadata)))
      ('worker
       (gptel-agent-runtime-worker-create
        :id (plist-get data :id)
        :session-id (plist-get data :session-id)
        :agent (plist-get data :agent)
        :step-id (plist-get data :step-id)
        :step-title (plist-get data :step-title)
        :tool (plist-get data :tool)
        :status (plist-get data :status)
        :prompt (plist-get data :prompt)
        :result (gptel-agent-runtime--data-to-struct
                 (plist-get data :result))
        :error (plist-get data :error)
        :attempts (or (plist-get data :attempts) 0)
        :max-retries (or (plist-get data :max-retries)
                         gptel-agent-runtime-worker-max-retries)
        :queued-at (plist-get data :queued-at)
        :started-at (plist-get data :started-at)
        :updated-at (plist-get data :updated-at)))
      ('organization-unit
       (gptel-agent-runtime-organization-unit-create
        :name (plist-get data :name)
        :purpose (plist-get data :purpose)
        :triggers (plist-get data :triggers)
        :agent-names (plist-get data :agent-names)
        :parent (plist-get data :parent)
        :escalation (plist-get data :escalation)
        :enabled-p (plist-get data :enabled-p)
        :metadata (plist-get data :metadata)))
      ('playbook
       (gptel-agent-runtime-playbook-create
        :id (plist-get data :id)
        :summary (plist-get data :summary)
        :triggers (plist-get data :triggers)
        :agent (plist-get data :agent)
        :skills (plist-get data :skills)
        :steps (plist-get data :steps)
        :source-session (plist-get data :source-session)
        :success-count (plist-get data :success-count)
        :failure-count (plist-get data :failure-count)
        :created-at (plist-get data :created-at)
        :updated-at (plist-get data :updated-at)
        :metadata (plist-get data :metadata)))
      ('session
       (gptel-agent-runtime-session-create
        :id (plist-get data :id)
        :role (plist-get data :role)
        :root-task (gptel-agent-runtime--data-to-struct
                    (plist-get data :root-task))
        :current-task (gptel-agent-runtime--data-to-struct
                       (plist-get data :current-task))
        :iteration (plist-get data :iteration)
        :observations (plist-get data :observations)
        :decisions (plist-get data :decisions)
        :tool-results (mapcar #'gptel-agent-runtime--data-to-struct
                              (plist-get data :tool-results))
        :workers (mapcar #'gptel-agent-runtime--data-to-struct
                         (plist-get data :workers))
        :process (or (plist-get data :process) 'hierarchical)
        :started-at (plist-get data :started-at)
        :updated-at (plist-get data :updated-at)))
      (_ data))))

(defun gptel-agent-runtime-memory-read-session (file)
  "Read runtime session memory FILE into structs."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (looking-at ";;;")
      (forward-line 1))
    (gptel-agent-runtime--data-to-struct (read (current-buffer)))))

(defun gptel-agent-runtime-memory-files ()
  "Return existing runtime memory files, newest first."
  (let ((dir (gptel-agent-runtime-memory-ensure-directory)))
    (sort (directory-files dir t "\\.el\\'")
          (lambda (a b)
            (time-less-p (file-attribute-modification-time
                          (file-attributes b))
                         (file-attribute-modification-time
                          (file-attributes a)))))))

(defun gptel-agent-runtime--text-score (query text)
  "Return a simple lexical relevance score for QUERY against TEXT."
  (let ((score 0)
        (case-fold-search t))
    (dolist (word (split-string query "[^[:alnum:]_-]+" t))
      (when (and (> (length word) 2)
                 (string-match-p (regexp-quote word) text))
        (setq score (1+ score))))
    score))

(defun gptel-agent-runtime-embedding-cache-path ()
  "Return the persistent embedding cache path."
  (expand-file-name "embedding-cache.el"
                    (gptel-agent-runtime-memory-ensure-directory)))

(defun gptel-agent-runtime-load-embedding-cache ()
  "Load the persistent embedding cache."
  (let ((path (gptel-agent-runtime-embedding-cache-path)))
    (setq gptel-agent-runtime-embedding-cache
          (if (and gptel-agent-runtime-embedding-cache-enabled
                   (file-exists-p path))
              (with-temp-buffer
                (insert-file-contents path)
                (read (current-buffer)))
            nil))))

(defun gptel-agent-runtime-save-embedding-cache ()
  "Save the persistent embedding cache."
  (when gptel-agent-runtime-embedding-cache-enabled
    (let ((path (gptel-agent-runtime-embedding-cache-path))
          (print-length nil)
          (print-level nil))
      (with-temp-file path
        (prin1 gptel-agent-runtime-embedding-cache (current-buffer))
        (insert "\n"))
      path)))

(defun gptel-agent-runtime--embedding-cache-key (text)
  "Return cache key for TEXT and current embedding model."
  (format "%s:%s"
          gptel-agent-runtime-embedding-model
          (secure-hash 'sha1 text)))

(defun gptel-agent-runtime--embedding-cache-get (text)
  "Return cached embedding for TEXT, or nil."
  (when gptel-agent-runtime-embedding-cache-enabled
    (unless gptel-agent-runtime-embedding-cache
      (gptel-agent-runtime-load-embedding-cache))
    (cdr (assoc (gptel-agent-runtime--embedding-cache-key text)
                gptel-agent-runtime-embedding-cache))))

(defun gptel-agent-runtime--embedding-cache-put (text embedding)
  "Cache EMBEDDING for TEXT."
  (when (and gptel-agent-runtime-embedding-cache-enabled embedding)
    (let ((key (gptel-agent-runtime--embedding-cache-key text)))
      (setq gptel-agent-runtime-embedding-cache
            (cons (cons key embedding)
                  (cl-remove key gptel-agent-runtime-embedding-cache
                             :key #'car :test #'equal)))
      (gptel-agent-runtime-save-embedding-cache))))

(defun gptel-agent-runtime--ollama-embedding (text)
  "Return Ollama embedding vector for TEXT, or nil."
  (when (eq gptel-agent-runtime-memory-retrieval-method 'ollama-embeddings)
    (or (gptel-agent-runtime--embedding-cache-get text)
        (let ((embedding
               (condition-case nil
                   (let* ((url-request-method "POST")
                          (url-request-extra-headers
                           '(("Content-Type" . "application/json")))
                          (url-request-data
                           (json-encode
                            `(("model" . ,gptel-agent-runtime-embedding-model)
                              ("prompt" . ,text))))
                          (buf (url-retrieve-synchronously
                                (gptel-agent-runtime--ollama-url "/api/embeddings")
                                t t 3)))
                     (when buf
                       (unwind-protect
                           (with-current-buffer buf
                             (goto-char (point-min))
                             (when (re-search-forward "\n\n" nil t)
                               (let* ((json-object-type 'plist)
                                      (json-array-type 'list)
                                      (json-key-type 'keyword)
                                      (data (json-read)))
                                 (plist-get data :embedding))))
                         (kill-buffer buf))))
                 (error nil))))
          (gptel-agent-runtime--embedding-cache-put text embedding)
          embedding))))

(defun gptel-agent-runtime--cosine-similarity (a b)
  "Return cosine similarity between numeric vectors A and B."
  (when (and a b (= (length a) (length b)) (> (length a) 0))
    (let ((dot 0.0)
          (amag 0.0)
          (bmag 0.0))
      (cl-loop for x in a
               for y in b
               do (setq dot (+ dot (* x y))
                        amag (+ amag (* x x))
                        bmag (+ bmag (* y y))))
      (if (or (zerop amag) (zerop bmag))
          0.0
        (/ dot (* (sqrt amag) (sqrt bmag)))))))

(defun gptel-agent-runtime-memory-retrieve (query &optional limit)
  "Return up to LIMIT memory snippets relevant to QUERY."
  (let ((limit (or limit gptel-agent-runtime-memory-retrieval-limit))
        scored)
    (let ((query-embedding
           (and (eq gptel-agent-runtime-memory-retrieval-method
                    'ollama-embeddings)
                (gptel-agent-runtime--ollama-embedding query))))
      (dolist (file (gptel-agent-runtime-memory-files))
      (when (file-readable-p file)
        (let ((text (with-temp-buffer
                      (insert-file-contents file nil 0
                                            (min 12000
                                                 (nth 7 (file-attributes file))))
                      (buffer-string))))
          (let* ((text-snippet (string-trim
                                (truncate-string-to-width text 1800 nil nil t)))
                 (text-embedding
                  (and query-embedding
                       (gptel-agent-runtime--ollama-embedding text-snippet)))
                 (embedding-score
                  (and query-embedding text-embedding
                       (gptel-agent-runtime--cosine-similarity
                        query-embedding text-embedding)))
                 (lexical-score (gptel-agent-runtime--text-score query text)))
            (push (list :file file
                        :score (or embedding-score lexical-score)
                        :method (if embedding-score 'ollama-embeddings 'lexical)
                        :text text-snippet)
                  scored))))))
    (cl-loop for item in (sort scored
                               (lambda (a b)
                                 (> (plist-get a :score)
                                    (plist-get b :score))))
             when (> (plist-get item :score) 0)
             collect item
             into results
             when (>= (length results) limit)
             return results
             finally return results)))

(defun gptel-agent-runtime-memory-context (query)
  "Return formatted memory context for QUERY."
  (let ((items (gptel-agent-runtime-memory-retrieve query)))
    (if items
        (mapconcat
         (lambda (item)
           (format "- Memory %s (%s score %s):\n%s"
                   (file-name-nondirectory (plist-get item :file))
                   (plist-get item :method)
                   (plist-get item :score)
                   (plist-get item :text)))
         items "\n\n")
      "No relevant prior memory found.")))

(provide 'gar-memory)

;;; gar-memory.el ends here
