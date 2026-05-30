;;; gar-failure-analytics.el --- visible failure-pattern aggregation -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Added 2026-05-30 as PR 18 of
;; the self-reflective / learning / memorising track.

;;; Commentary:

;; Reads `--last-verifier-verdicts' (in-memory, 50 most recent) and
;; `--trajectories' (in-memory, up to 200 most recent), groups
;; failures by tool and by reason pattern, surfaces top-N in
;; mission control + a detailed report buffer.
;;
;; Pure-functional: writes nothing to disk, runs in microseconds, can
;; be called every dashboard refresh without overhead.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar gptel-agent-runtime--last-verifier-verdicts)
(defvar gptel-agent-runtime--trajectories)

(declare-function gptel-agent-runtime-trajectory-outcome
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-goal
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-verifier-verdicts
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-steps
                  "gptel-agent-runtime" (traj))
(declare-function gptel-agent-runtime-trajectory-step-suggested-tool
                  "gptel-agent-runtime" (step))
(declare-function gptel-agent-runtime-trajectory-step-result-status
                  "gptel-agent-runtime" (step))
(declare-function gptel-agent-runtime-trajectory-step-result-error
                  "gptel-agent-runtime" (step))

(defcustom gptel-agent-runtime-failure-analytics-window 100
  "Number of recent trajectories to scan for failure aggregation.
Bounded to keep the dashboard render time predictable; the
in-memory ring is already capped at 200 (per
`trajectories-max-memory') so this is rarely the binding limit."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-failure-analytics-top-n 5
  "How many entries to show in the per-tool and per-reason rankings."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defconst gptel-agent-runtime--failure-analytics-reason-patterns
  '(("not found"             . "\\bnot found\\b\\|\\bnotfound\\b")
    ("ambiguous heading"     . "\\bambiguous\\b")
    ("policy denied"         . "\\bdenied\\b\\|\\bblocked\\b\\|\\bcapability\\b")
    ("schema violation"      . "\\bschema\\b.*\\bviolat")
    ("void function/symbol"  . "\\bvoid-function\\b\\|\\bvoid-variable\\b\\|definition is void\\b")
    ("timeout"               . "\\btimed? ?out\\b")
    ("path protected"        . "\\bprotected\\b")
    ("quarantined"           . "\\bquarantin")
    ("incomplete answer"     . "\\bincluded [0-9]+ of [0-9]+ items"))
  "Regexps applied to verdict/error text to bucket failures.
Order matters -- the first matching pattern wins, so put more
specific patterns earlier.")

(defun gptel-agent-runtime--failure-analytics-classify-reason (text)
  "Return the bucket label for failure TEXT, or `\"other\"' when nothing matches."
  (if (or (null text) (string-empty-p text))
      "other"
    (let ((case-fold-search t)
          (result nil))
      (catch 'done
        (dolist (entry gptel-agent-runtime--failure-analytics-reason-patterns)
          (when (string-match-p (cdr entry) text)
            (setq result (car entry))
            (throw 'done nil))))
      (or result "other"))))

(defun gptel-agent-runtime--failure-analytics-failures-from-verdicts ()
  "Walk the in-memory ring of verifier verdicts and return failure
plists -- one per `:passed nil' verdict -- with shape
`(:tool TOOL :reason REASON :step STEP :at TIMESTAMP)'."
  (let ((collected '()))
    (dolist (entry (and (boundp 'gptel-agent-runtime--last-verifier-verdicts)
                        gptel-agent-runtime--last-verifier-verdicts))
      (let* ((at (car entry))
             (verdict (cdr entry)))
        (when (and verdict (not (plist-get verdict :passed)))
          (push (list :tool (or (plist-get verdict :tool) "<unknown>")
                      :reason (gptel-agent-runtime--failure-analytics-classify-reason
                               (plist-get verdict :reason))
                      :reason-text (plist-get verdict :reason)
                      :step (or (plist-get verdict :step) "")
                      :at at
                      :source 'verifier)
                collected))))
    (nreverse collected)))

(defun gptel-agent-runtime--failure-analytics-failures-from-trajectories ()
  "Walk the in-memory trajectory ring and return failure plists.
For each trajectory with `outcome 'failure', extracts the last
failing step (its tool + result-error) plus the goal."
  (let ((collected '())
        (window gptel-agent-runtime-failure-analytics-window))
    (dolist (traj (and (boundp 'gptel-agent-runtime--trajectories)
                       (let ((traj-list gptel-agent-runtime--trajectories))
                         (cl-subseq traj-list 0
                                    (min window (length traj-list))))))
      (let ((outcome (gptel-agent-runtime-trajectory-outcome traj)))
        (when (eq outcome 'failure)
          (let* ((steps (gptel-agent-runtime-trajectory-steps traj))
                 (failing-step
                  (cl-find-if
                   (lambda (s)
                     (let ((status (gptel-agent-runtime-trajectory-step-result-status
                                    s)))
                       (and status (not (eq status 'ok)))))
                   steps))
                 (tool (and failing-step
                            (gptel-agent-runtime-trajectory-step-suggested-tool
                             failing-step)))
                 (err (and failing-step
                           (gptel-agent-runtime-trajectory-step-result-error
                            failing-step))))
            (push (list :tool (or tool "<unknown>")
                        :reason (gptel-agent-runtime--failure-analytics-classify-reason
                                 err)
                        :reason-text err
                        :goal (gptel-agent-runtime-trajectory-goal traj)
                        :source 'trajectory)
                  collected)))))
    (nreverse collected)))

(defun gptel-agent-runtime--failure-analytics-all-failures ()
  "Return the union of verdict + trajectory failures."
  (append (gptel-agent-runtime--failure-analytics-failures-from-verdicts)
          (gptel-agent-runtime--failure-analytics-failures-from-trajectories)))

(defun gptel-agent-runtime--failure-analytics-top-counts (key failures)
  "Group FAILURES by KEY (`:tool' or `:reason'), return alist of
(KEY-VALUE . COUNT) sorted by descending count, capped at
`failure-analytics-top-n'."
  (let ((counts (make-hash-table :test #'equal))
        (n gptel-agent-runtime-failure-analytics-top-n))
    (dolist (f failures)
      (let ((v (or (plist-get f key) "<unknown>")))
        (puthash v (1+ (gethash v counts 0)) counts)))
    (let* ((pairs nil))
      (maphash (lambda (k v) (push (cons k v) pairs)) counts)
      (setq pairs (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
      (cl-subseq pairs 0 (min n (length pairs))))))

(defun gptel-agent-runtime-failure-analytics-stats ()
  "Return a stats plist:
`(:total N :by-tool ((TOOL . COUNT) ...) :by-reason ((REASON . COUNT) ...))'.
Suitable for both the mission-control summary and the detailed report."
  (let* ((failures (gptel-agent-runtime--failure-analytics-all-failures))
         (total (length failures))
         (by-tool (gptel-agent-runtime--failure-analytics-top-counts
                   :tool failures))
         (by-reason (gptel-agent-runtime--failure-analytics-top-counts
                     :reason failures)))
    (list :total total
          :by-tool by-tool
          :by-reason by-reason)))

(defun gptel-agent-runtime-failure-analytics-summary ()
  "Return a multi-line string for the mission-control `Failure
patterns' section."
  (let* ((stats (gptel-agent-runtime-failure-analytics-stats))
         (total (plist-get stats :total))
         (by-tool (plist-get stats :by-tool))
         (by-reason (plist-get stats :by-reason))
         (format-line
          (lambda (pair)
            (format "    %-28s  %d" (car pair) (cdr pair)))))
    (if (zerop total)
        "  (no failures recorded yet -- the substrate is healthy or empty)"
      (concat
       (format "  Total recent failures: %d\n" total)
       "  By tool:\n"
       (if by-tool
           (mapconcat format-line by-tool "\n")
         "    (no per-tool data)")
       "\n  By reason:\n"
       (if by-reason
           (mapconcat format-line by-reason "\n")
         "    (no per-reason data)")
       "\n  Report: M-x gptel-agent-runtime-failure-report"))))

(defcustom gptel-agent-runtime-failure-report-buffer-name
  "*gptel-agent-failure-report*"
  "Buffer name for the detailed failure report."
  :type 'string
  :group 'gptel-agent-runtime)

;;;###autoload
(defun gptel-agent-runtime-failure-report ()
  "Open a detailed failure-pattern report covering the recent
trajectory + verifier-verdict ring.  Read-only buffer."
  (interactive)
  (let* ((stats (gptel-agent-runtime-failure-analytics-stats))
         (failures (gptel-agent-runtime--failure-analytics-all-failures))
         (buf (get-buffer-create
               gptel-agent-runtime-failure-report-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Failure-pattern report  (recent %d records)\n\n"
                        (plist-get stats :total)))
        (insert "By tool:\n")
        (if (plist-get stats :by-tool)
            (dolist (pair (plist-get stats :by-tool))
              (insert (format "  %-30s  %d\n" (car pair) (cdr pair))))
          (insert "  (none)\n"))
        (insert "\nBy reason:\n")
        (if (plist-get stats :by-reason)
            (dolist (pair (plist-get stats :by-reason))
              (insert (format "  %-30s  %d\n" (car pair) (cdr pair))))
          (insert "  (none)\n"))
        (insert "\nRecent failure messages (last 20):\n\n")
        (dolist (f (cl-subseq failures 0 (min 20 (length failures))))
          (insert (format "  [%s] tool=%s reason=%s\n"
                          (or (plist-get f :source) "?")
                          (or (plist-get f :tool) "?")
                          (or (plist-get f :reason) "?")))
          (when (plist-get f :reason-text)
            (insert (format "      %s\n"
                            (string-trim
                             (substring
                              (or (plist-get f :reason-text) "")
                              0 (min 200
                                     (length (or (plist-get f :reason-text)
                                                 "")))))))))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)))

(provide 'gar-failure-analytics)

;;; gar-failure-analytics.el ends here
