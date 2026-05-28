;;; gar-safety.el --- mission-control unified dashboard -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Now reduced to the mission-control
;; buffer; will be removed in PR 5 of the gar-safety sub-split when
;; mission-control moves to gar-mission-control.

;;; Commentary:

;; The mission-control buffer is a read-only dashboard summarizing the
;; live state of every submodule in one place: substrate (tick, event
;; pump, subscribers, capability enforcement), policy (active preset,
;; confirmation/wrap flags), recent events, recent evidence with taint,
;; quarantine size + promoted IDs, canary pass/fail summary, skeptic
;; verdicts, exploration & learning (novelty / synthesis / playbooks),
;; and per-agent capability allowlists. Subscribes to `tick' on first
;; render so subsequent ticks refresh the buffer in place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Defvars and declare-functions for every cross-module symbol the
;; dashboard reads. Late binding: defun bodies resolve the symbols at
;; call time; these declarations keep byte-compile warning-free.

;; gar-core defcustoms / defvars.
(defvar gptel-agent-runtime-policy-preset)
(defvar gptel-agent-runtime-wrap-untrusted-context)
(defvar gptel-agent-runtime-require-confirmation-for-risky-actions)
(defvar gptel-agent-runtime-auto-execute-safe-actions)
(defvar gptel-agent-runtime-tick-counter)
(defvar gptel-agent-runtime-state-schema-version)
(defvar gptel-agent-runtime-idle-pump-interval)
(defvar gptel-agent-runtime-agent-registry)

;; gar-substrate defvars and helpers.
(defvar gptel-agent-runtime--evidence-trace)
(defvar gptel-agent-runtime--event-subscribers)
(defvar gptel-agent-runtime--last-dispatched-events)
(defvar gptel-agent-runtime--idle-pump-timer)
(declare-function gptel-agent-runtime--timestamp "gptel-agent-runtime" ())
(declare-function gptel-agent-runtime--shorten "gptel-agent-runtime"
                  (text &optional max))
(declare-function gptel-agent-runtime-subscribe "gptel-agent-runtime"
                  (type handler))
(declare-function gptel-agent-runtime-event-type "gptel-agent-runtime" (event))
(declare-function gptel-agent-runtime-event-created-at
                  "gptel-agent-runtime" (event))

;; gar-core struct accessors (evidence, agent).
(declare-function gptel-agent-runtime-evidence-id "gptel-agent-runtime" (ev))
(declare-function gptel-agent-runtime-evidence-text "gptel-agent-runtime" (ev))
(declare-function gptel-agent-runtime-evidence-taint "gptel-agent-runtime" (ev))
(declare-function gptel-agent-runtime-evidence-source-type
                  "gptel-agent-runtime" (ev))
(declare-function gptel-agent-runtime-agent-name "gptel-agent-runtime" (agent))
(declare-function gptel-agent-runtime-agent-role "gptel-agent-runtime" (agent))
(declare-function gptel-agent-runtime-agent-allowed-caps "gptel-agent-runtime"
                  (agent))

;; gar-policy (loaded before gar-safety).
(defvar gptel-agent-runtime-capability-enforcement-enabled)

;; gar-quarantine (loaded before gar-safety).
(defvar gptel-agent-runtime-quarantine-untrusted-output)
(defvar gptel-agent-runtime-quarantine-pre-flight-enabled)
(defvar gptel-agent-runtime--promoted-evidence-ids)
(declare-function gptel-agent-runtime-quarantined-evidence
                  "gar-quarantine" ())

;; gar-canaries (loaded after gar-safety; late-bound).
(defvar gptel-agent-runtime--last-canary-results)

;; gar-skeptic (loaded before gar-safety).
(defvar gptel-agent-runtime-skeptic-enabled)
(defvar gptel-agent-runtime-skeptic-mode)
(defvar gptel-agent-runtime-skeptic-budget-ms)
(defvar gptel-agent-runtime-skeptic-trigger-risks)
(defvar gptel-agent-runtime-skeptic-trigger-caps)
(defvar gptel-agent-runtime--last-skeptic-verdicts)

;; gar-memory (loaded after gar-safety; late-bound).
(defvar gptel-agent-runtime-novelty-threshold)
(defvar gptel-agent-runtime-novelty-min-tokens)
(defvar gptel-agent-runtime-strategy-synthesis-enabled)
(defvar gptel-agent-runtime-strategy-synthesis-interval-ticks)
(declare-function gptel-agent-runtime-list-playbook-candidates
                  "gar-memory" ())
(declare-function gptel-agent-runtime-rank-playbooks-by-success
                  "gar-memory" (&optional limit))
(declare-function gptel-agent-runtime-playbook-success-rate
                  "gar-memory" (playbook))
(declare-function gptel-agent-runtime-playbook-id "gptel-agent-runtime"
                  (playbook))
(declare-function gptel-agent-runtime-playbook-summary "gptel-agent-runtime"
                  (playbook))

;; ----- Mission control unified dashboard -----

(defcustom gptel-agent-runtime-mission-control-buffer-name "*gptel-agent-mission-control*"
  "Buffer name used for the unified mission-control dashboard."
  :type 'string
  :group 'gptel-agent-runtime)

(defvar gptel-agent-runtime--mission-control-subscribed nil
  "Non-nil when the mission-control auto-refresh subscriber is installed.")

(defun gptel-agent-runtime--mission-control-section (title body)
  "Insert a TITLE section with BODY (a string) into the current buffer."
  (insert (format "=== %s ===\n%s\n\n" title body)))

(defun gptel-agent-runtime--mission-control-recent-events (limit)
  "Return a string with the LIMIT most recent dispatched events for the dashboard."
  (let* ((entries gptel-agent-runtime--last-dispatched-events)
         (n (min (or limit 8) (length entries))))
    (if (zerop n)
        "  (no events dispatched yet)"
      (mapconcat
       (lambda (entry)
         (let ((evt (plist-get entry :event)))
           (format "  %s  %s  handlers=%d errors=%d"
                   (gptel-agent-runtime-event-created-at evt)
                   (gptel-agent-runtime-event-type evt)
                   (length (plist-get entry :handlers))
                   (length (plist-get entry :errors)))))
       (cl-subseq entries 0 n)
       "\n"))))

(defun gptel-agent-runtime--mission-control-recent-evidence (limit)
  "Return a string with the LIMIT most recent evidence records."
  (let* ((trace gptel-agent-runtime--evidence-trace)
         (n (min (or limit 6) (length trace))))
    (if (zerop n)
        "  (no evidence yet)"
      (mapconcat
       (lambda (ev)
         (format "  %s [%s/%s] %s"
                 (gptel-agent-runtime-evidence-id ev)
                 (gptel-agent-runtime-evidence-source-type ev)
                 (gptel-agent-runtime-evidence-taint ev)
                 (gptel-agent-runtime--shorten
                  (gptel-agent-runtime-evidence-text ev) 100)))
       (cl-subseq trace 0 n)
       "\n"))))

(defun gptel-agent-runtime--mission-control-canary-summary ()
  "Return a string describing the most recent canary run."
  (if (null gptel-agent-runtime--last-canary-results)
      "  (canaries have not been run; M-x gptel-agent-runtime-run-injection-canaries)"
    (let ((pass (cl-count-if (lambda (r) (nth 1 r))
                             gptel-agent-runtime--last-canary-results))
          (total (length gptel-agent-runtime--last-canary-results))
          (fails (cl-remove-if (lambda (r) (nth 1 r))
                               gptel-agent-runtime--last-canary-results)))
      (concat (format "  %d/%d passed" pass total)
              (when fails
                (concat "\n  failing: "
                        (mapconcat (lambda (r) (nth 0 r)) fails ", ")))))))

(defun gptel-agent-runtime-mission-control ()
  "Open the unified mission-control dashboard buffer.
Shows the OpenClaw tick, idle-pump state, recent dispatched events, active
policy preset, recent evidence flow with taint, quarantine size, canary
status, and the registered agent capability allowlist."
  (interactive)
  (with-current-buffer (get-buffer-create
                        gptel-agent-runtime-mission-control-buffer-name)
    (erase-buffer)
    (insert (format "gptel-agent-runtime mission control\nRendered at: %s\n\n"
                    (gptel-agent-runtime--timestamp)))
    (gptel-agent-runtime--mission-control-section
     "Substrate"
     (format "  Tick: %s\n  Idle pump: %s (every %ds)\n  Schema: %s\n  Subscribers: %d types\n  Capability enforcement: %s"
             (or gptel-agent-runtime-tick-counter 0)
             (if gptel-agent-runtime--idle-pump-timer "ON" "off")
             gptel-agent-runtime-idle-pump-interval
             gptel-agent-runtime-state-schema-version
             (length gptel-agent-runtime--event-subscribers)
             (if gptel-agent-runtime-capability-enforcement-enabled "ON" "off")))
    (gptel-agent-runtime--mission-control-section
     "Policy"
     (format "  Preset: %s\n  Confirm for risky: %s\n  Auto-execute safe: %s\n  Wrap untrusted: %s\n  Quarantine untrusted: %s (pre-flight=%s)"
             gptel-agent-runtime-policy-preset
             gptel-agent-runtime-require-confirmation-for-risky-actions
             gptel-agent-runtime-auto-execute-safe-actions
             gptel-agent-runtime-wrap-untrusted-context
             gptel-agent-runtime-quarantine-untrusted-output
             gptel-agent-runtime-quarantine-pre-flight-enabled))
    (gptel-agent-runtime--mission-control-section
     "Recent events"
     (gptel-agent-runtime--mission-control-recent-events 8))
    (gptel-agent-runtime--mission-control-section
     "Recent evidence"
     (gptel-agent-runtime--mission-control-recent-evidence 6))
    (gptel-agent-runtime--mission-control-section
     "Quarantine"
     (let* ((q (gptel-agent-runtime-quarantined-evidence)))
       (if (null q)
           "  (no quarantined evidence)"
         (concat (format "  %d items quarantined; %d promoted IDs\n"
                         (length q)
                         (length gptel-agent-runtime--promoted-evidence-ids))
                 (mapconcat (lambda (e)
                              (format "  - %s [%s]"
                                      (gptel-agent-runtime-evidence-id e)
                                      (gptel-agent-runtime-evidence-source-type e)))
                            (cl-subseq q 0 (min 5 (length q)))
                            "\n")))))
    (gptel-agent-runtime--mission-control-section
     "Injection canaries"
     (gptel-agent-runtime--mission-control-canary-summary))
    (gptel-agent-runtime--mission-control-section
     "Skeptic"
     (format "  Enabled: %s   Mode: %s   Budget: %dms\n  Trigger risks: %s\n  Trigger caps: %s\n  Recent verdicts: %d\n%s"
             gptel-agent-runtime-skeptic-enabled
             gptel-agent-runtime-skeptic-mode
             gptel-agent-runtime-skeptic-budget-ms
             gptel-agent-runtime-skeptic-trigger-risks
             gptel-agent-runtime-skeptic-trigger-caps
             (length gptel-agent-runtime--last-skeptic-verdicts)
             (if (null gptel-agent-runtime--last-skeptic-verdicts)
                 "  (no verdicts yet)"
               (mapconcat
                (lambda (entry)
                  (let ((v (cdr entry)))
                    (format "  %s  tool=%s  risk=%s  concerns=%d"
                            (car entry)
                            (plist-get v :tool)
                            (plist-get v :risk)
                            (length (plist-get v :concerns)))))
                (cl-subseq gptel-agent-runtime--last-skeptic-verdicts
                           0 (min 5 (length gptel-agent-runtime--last-skeptic-verdicts)))
                "\n"))))
    (gptel-agent-runtime--mission-control-section
     "Exploration & learning"
     (format "  Novelty threshold: %.2f   Min tokens: %d\n  Strategy synthesis: %s   Interval: every %d ticks\n  Candidate playbooks pending: %d\n  Top playbooks (by success rate):\n%s"
             gptel-agent-runtime-novelty-threshold
             gptel-agent-runtime-novelty-min-tokens
             gptel-agent-runtime-strategy-synthesis-enabled
             gptel-agent-runtime-strategy-synthesis-interval-ticks
             (length (or (gptel-agent-runtime-list-playbook-candidates) '()))
             (let ((top (gptel-agent-runtime-rank-playbooks-by-success 5)))
               (if (null top)
                   "    (no playbooks registered)"
                 (mapconcat
                  (lambda (pb)
                    (let ((rate (gptel-agent-runtime-playbook-success-rate pb)))
                      (format "    %s  %s"
                              (or (gptel-agent-runtime-playbook-id pb)
                                  (gptel-agent-runtime-playbook-summary pb))
                              (if rate (format "%.0f%%" (* 100 rate)) "unused"))))
                  top "\n")))))
    (gptel-agent-runtime--mission-control-section
     "Agents / capability allowlists"
     (if (null gptel-agent-runtime-agent-registry)
         "  (no agents registered)"
       (mapconcat
        (lambda (a)
          (format "  %s [%s]  caps=%s"
                  (gptel-agent-runtime-agent-name a)
                  (gptel-agent-runtime-agent-role a)
                  (or (gptel-agent-runtime-agent-allowed-caps a) '(any))))
        gptel-agent-runtime-agent-registry
        "\n")))
    (goto-char (point-min))
    (special-mode))
  (unless gptel-agent-runtime--mission-control-subscribed
    (gptel-agent-runtime-subscribe
     'tick
     (lambda (_e)
       (when (get-buffer gptel-agent-runtime-mission-control-buffer-name)
         ;; Refresh in place without stealing window focus.
         (save-window-excursion
           (gptel-agent-runtime-mission-control)))))
    (setq gptel-agent-runtime--mission-control-subscribed t))
  (display-buffer gptel-agent-runtime-mission-control-buffer-name))

(provide 'gar-safety)

;;; gar-safety.el ends here
