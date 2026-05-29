;;; gar-test-fake-llm.el --- Synchronous gptel-request stub for e2e loop tests -*- lexical-binding: t; -*-

;; Lets ERT tests drive the autonomous loop end-to-end without an Ollama
;; backend. `gar-test-with-fake-llm' replaces `gptel-request' with a
;; dispatcher that classifies each prompt (plan / direct / reflection /
;; review / refinement) and synchronously invokes the request's
;; `:callback' with a canned response.

;;; Code:

(require 'cl-lib)

(defvar gar-test--fake-llm-responses nil
  "Per-test plist mapping prompt kinds to canned responses.
Recognized kinds: `:plan', `:direct', `:reflection', `:review',
`:refinement'.  Unspecified kinds fall back to
`gar-test--default-fake-response'.")

(defvar gar-test--fake-llm-call-log nil
  "Reverse-chronological list of (KIND . PROMPT) for each fake LLM call.
Tests can inspect this to assert which prompt kinds were exercised.")

(defun gar-test--classify-prompt (prompt system)
  "Best-effort classification of (PROMPT, SYSTEM) into a prompt kind."
  (let ((p (or prompt "")) (s (or system "")))
    (cond
     ((string-match-p "Produce the requested user-visible result" p) :direct)
     ((string-match-p "Decide the next loop state" p) :reflection)
     ((string-match-p "Review this plan before execution" p) :review)
     ((string-match-p "Refine\\|playbook candidate\\|playbook steps" p)
      :refinement)
     ((string-match-p "playbook\\|skill" s) :refinement)
     (t :plan))))

(defun gar-test--default-fake-response (kind)
  "Return a sensible default canned response for KIND."
  (pcase kind
    (:plan "{\"steps\":[{\"title\":\"Answer directly\",\"rationale\":\"Simple goal\",\"risk\":\"safe\"}]}")
    (:direct "Stub answer.")
    (:reflection "{\"status\":\"done\",\"reflection\":\"Completed.\"}")
    (:review "{\"verdict\":\"approve\",\"reason\":\"Plan looks fine.\"}")
    (:refinement
     "{\"id\":\"refined-stub\",\"summary\":\"Refined\",\"triggers\":[\"x\"],\"steps\":[{\"title\":\"step\"}]}")
    (_ "")))

(defun gar-test--fake-gptel-request (prompt &rest args)
  "Stand-in for `gptel-request'.
Classifies PROMPT (with optional :system in ARGS), records the call in
`gar-test--fake-llm-call-log', then synchronously invokes the request's
`:callback' with the matched canned response."
  (let* ((system (plist-get args :system))
         (callback (plist-get args :callback))
         (kind (gar-test--classify-prompt prompt system))
         (response (or (plist-get gar-test--fake-llm-responses kind)
                       (gar-test--default-fake-response kind))))
    (push (cons kind prompt) gar-test--fake-llm-call-log)
    (when callback (funcall callback response nil))
    'fake-request))

(defmacro gar-test-with-fake-llm (responses &rest body)
  "Evaluate BODY with `gptel-request' replaced by the fake-LLM dispatcher.
RESPONSES is a plist mapping prompt kinds to strings.  Resets the call
log on entry; body code can inspect `gar-test--fake-llm-call-log'
afterwards to assert which prompt kinds were exercised."
  (declare (indent 1))
  `(let ((gar-test--fake-llm-responses ,responses)
         (gar-test--fake-llm-call-log nil))
     (cl-letf (((symbol-function 'gptel-request)
                #'gar-test--fake-gptel-request))
       ,@body)))

(defmacro gar-test-with-sandboxed-state (&rest body)
  "Run BODY with all package state (dirs, registries, ring buffers) sandboxed.
Each test gets a fresh temp memory dir, empty trajectory ring, empty
experiments list, fresh SQLite file, and an empty event-subscribers
table seeded with whatever the package wired at load time."
  (declare (indent 0))
  `(let* ((tmp-root (make-temp-file "gar-e2e-" t))
          (gptel-agent-runtime-memory-directory tmp-root)
          (gptel-agent-runtime-trajectories-directory
           (expand-file-name "trajectories/" tmp-root))
          (gptel-agent-runtime-experiments-directory
           (expand-file-name "experiments/" tmp-root))
          (gptel-agent-runtime-sqlite-file
           (expand-file-name "agent.sqlite" tmp-root))
          (gptel-agent-runtime--trajectories nil)
          (gptel-agent-runtime--experiments nil)
          (gptel-agent-runtime--sqlite-db nil)
          (gptel-agent-runtime-enable-plan-review nil)
          (gptel-agent-runtime-confirm-for-risky nil))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp-root)
         (delete-directory tmp-root t)))))

(provide 'gar-test-fake-llm)

;;; gar-test-fake-llm.el ends here
