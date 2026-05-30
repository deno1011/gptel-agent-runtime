;;; gar-live-claude-test.el --- live Anthropic Claude integration tests -*- lexical-binding: t; -*-

;; Real-LLM end-to-end tests against the Anthropic API (Claude Haiku
;; by default).  Mirrors `gar-live-model-test' which targets a local
;; Ollama; this file covers the user's actual daily backend so an
;; Anthropic / gptel-anthropic / Haiku-behaviour regression shows up
;; in CI instead of in production use.
;;
;; OPT-IN by design.  Each test is gated by THREE `skip-unless':
;;   1. `ANTHROPIC_API_KEY' is set in the environment.
;;   2. `GAR_RUN_SLOW' is set (same gate as the Ollama live tests).
;;   3. `GAR_RUN_PAID' is set -- paid-API tests are gated extra
;;      because they cost real money (about a tenth of a cent per
;;      full run; trivial but principled to opt in explicitly).
;;
;; The default suite SKIPS everything in this file transparently.
;; To run:
;;
;;   GAR_RUN_SLOW=1 GAR_RUN_PAID=1 emacs -Q --batch -L . -L test \
;;     -l test/test-helper.el \
;;     -l test/gar-test-fake-llm.el \
;;     -l test/gar-live-claude-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Cost estimate at default model (claude-haiku-4-5-20251001):
;;   Single tests:  ~200 in + 50 out tokens = ~0.0001 USD each
;;   Full session:  ~1500 in + 300 out tokens = ~0.0008 USD
;;   Whole suite:   ~0.005 USD per run.

;;; Code:

(require 'test-helper)
(require 'gar-test-fake-llm)
(require 'gar-live-test-shared)
(require 'gptel-anthropic)

;; --- Configuration ---

(defvar gar-live-claude-test--model 'claude-haiku-4-5-20251001
  "Anthropic model symbol the live tests use.  Defaults to Haiku
because it's the cheapest and fastest of the line; tests don't
need the higher-end models' reasoning depth.")

;; --- Availability probe ---

(defun gar-live-claude-test--api-key-available-p ()
  "Return non-nil when an Anthropic API key is exported in the env."
  (let ((k (getenv "ANTHROPIC_API_KEY")))
    (and k (stringp k) (> (length k) 10))))

;; --- Backend setup ---

(defmacro gar-live-claude-test-with-backend (&rest body)
  "Bind a minimal gptel Anthropic backend and run BODY.
Restores prior `gptel-backend' / `gptel-model'.  Reads the API key
from the env on each call -- if your config rotates the key,
the test picks it up automatically."
  (declare (indent 0))
  `(let* ((model-sym gar-live-claude-test--model)
          (orig-backend gptel-backend)
          (orig-model gptel-model)
          (gptel-use-tools nil) ; live tests don't exercise tool-call here
          (gptel-stream nil))
     (unwind-protect
         (progn
           (setq gptel-backend
                 (gptel-make-anthropic "live-claude-test"
                   :stream nil
                   :key (lambda () (getenv "ANTHROPIC_API_KEY"))
                   :models (list model-sym)))
           (setq gptel-model model-sym)
           ,@body)
       (setq gptel-backend orig-backend
             gptel-model orig-model))))

;; ============================================================================
;; The live Claude tests
;; ============================================================================

;; --- 1. Smoke test: basic non-empty response ---

(ert-deftest gar-live-claude-basic-response-nonempty ()
  "Claude returns non-empty text for a minimal prompt."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (let ((response (gar-live-test--sync-request
                     "Reply with the word READY and nothing else.")))
      (should (stringp response))
      (should (> (length (string-trim response)) 0)))))

;; --- 2. Direct factual question ---

(ert-deftest gar-live-claude-direct-question-contains-expected-token ()
  "Direct factual prompt returns a response containing the expected substring."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (let ((response (gar-live-test--sync-request
                     "What is 2 + 2? Reply with just the number.")))
      (should (string-match-p "4" response)))))

;; --- 3. Planner-style prompt returns parseable JSON with steps array ---

(ert-deftest gar-live-claude-planner-returns-json-with-steps ()
  "Claude follows the planner system prompt and returns valid JSON
with a non-empty steps array."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (let* ((response (gar-live-test--sync-request
                      "GOAL:\nRead the file /etc/hostname and report what it contains.\n\nAVAILABLE TOOLS:\nread_file, direct_response\n\nProduce the executable plan as JSON."
                      :system (gptel-agent-runtime--planner-system)))
           (json (gptel-agent-runtime--extract-json response))
           (parsed (and json (ignore-errors
                               (gptel-agent-runtime--json-read-plist
                                (gptel-agent-runtime--repair-json-string
                                 json))))))
      (should parsed)
      (let ((steps (plist-get parsed :steps)))
        (should (listp steps))
        (should (>= (length steps) 1))
        (let ((first (car steps)))
          (should (stringp (plist-get first :title))))))))

;; --- 4. Reflection prompt returns a valid status verb ---

(ert-deftest gar-live-claude-reflection-returns-known-status ()
  "Reflection-shaped prompt yields JSON with :status from the canonical enum."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (let* ((prompt
            "GOAL:\nGreet the user.\n\nSTEP:\nSay hello.\n\nRESULT STATUS: ok\nOUTPUT:\nHello!\nERROR:\nnil\n\nDecide the next loop state.")
           (system "Return only a single JSON object with keys \"status\" and \"reflection\". The status field MUST be one of: continue, replan, done, failed.")
           (response (gar-live-test--sync-request prompt :system system))
           (json (gptel-agent-runtime--extract-json response))
           (parsed (and json (ignore-errors
                               (gptel-agent-runtime--json-read-plist
                                (gptel-agent-runtime--repair-json-string
                                 json))))))
      (should parsed)
      (should (member (plist-get parsed :status)
                      '("continue" "replan" "done" "failed"))))))

;; --- 5. Backend binding sanity (no network) ---

(ert-deftest gar-live-claude-uses-the-configured-model ()
  "After binding the test backend, the active model symbol matches."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (should (eq gar-live-claude-test--model gptel-model))
    (should (gptel-anthropic-p gptel-backend))
    (should (string= "live-claude-test"
                     (gptel-backend-name gptel-backend)))))

;; --- 6. Instruction-following sanity ---

(ert-deftest gar-live-claude-instruction-following-short-answer ()
  "Instruction-following sanity: a `reply with just X' prompt yields a
short answer.  Claude is much stronger here than 7B local models;
the test is mostly a regression-detector for `the response became
chatty for no reason'."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-live-claude-test-with-backend
    (let* ((response (gar-live-test--sync-request
                      "Reply with exactly the single word: OK"))
           (clean (string-trim (downcase response))))
      (should (string-match-p "ok" clean))
      ;; Haiku is good at this -- the limit is generous to absorb
      ;; trailing punctuation like "OK." or "OK!".
      (should (< (length clean) 20)))))

;; --- 7. Full session against the live model ---

(ert-deftest gar-live-claude-full-session-produces-trajectory ()
  "Drive `gptel-agent-runtime-start' against Claude and assert a
trajectory was recorded for the session.

Same shape as `gar-live-full-session-produces-trajectory' on the
Ollama side, but uses Claude.  Substantially faster than the Ollama
equivalent (~5-15s vs ~45-120s) because Claude doesn't cold-load
on first call."
  (skip-unless (gar-live-claude-test--api-key-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_PAID"))
  (gar-test-with-sandboxed-state
    (gar-live-claude-test-with-backend
      (let* ((finalized nil)
             (sub-fn (lambda (_e) (setq finalized t))))
        (gptel-agent-runtime-subscribe 'session-finalized sub-fn)
        (unwind-protect
            (progn
              (gptel-agent-runtime-start
               "Say the word READY and nothing else.")
              ;; Claude is fast -- 60s is generous.
              (let ((deadline (+ (float-time) 60)))
                (while (and (not finalized) (< (float-time) deadline))
                  (accept-process-output nil 0.1)))
              (should finalized)
              (should (>= (length gptel-agent-runtime--trajectories) 1))
              (let ((traj (car gptel-agent-runtime--trajectories)))
                (should (gptel-agent-runtime-trajectory-p traj))
                (should (memq (gptel-agent-runtime-trajectory-outcome traj)
                              '(success failure)))))
          (let ((subs (alist-get 'session-finalized
                                 gptel-agent-runtime--event-subscribers)))
            (setf (alist-get 'session-finalized
                             gptel-agent-runtime--event-subscribers)
                  (cl-remove sub-fn subs :test #'eq))))))))

(provide 'gar-live-claude-test)

;;; gar-live-claude-test.el ends here
