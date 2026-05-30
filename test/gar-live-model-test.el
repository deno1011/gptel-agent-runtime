;;; gar-live-model-test.el --- live Ollama instruct-model integration tests -*- lexical-binding: t; -*-

;; Real-LLM end-to-end tests that hit the user's local Ollama.
;;
;; OPT-IN by design: each test is gated by two `skip-unless' clauses:
;;   1. Ollama must be reachable at localhost:11434.
;;   2. The env var GAR_RUN_SLOW must be set.
;;
;; The default suite (`emacs -Q --batch ... -f ert-run-tests-batch-and-exit')
;; therefore SKIPS all live tests transparently. To run them:
;;
;;   GAR_RUN_SLOW=1 emacs -Q --batch -L . -L test \
;;     -l test/test-helper.el \
;;     -l test/gar-test-fake-llm.el \
;;     -l test/gar-live-model-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The opt-in is necessary because each live call is 10-80s and the
;; full-session test orchestrates THREE chained calls. Standalone
;; performance is fine; bundled with the 200+ offline tests, Ollama
;; saturates and individual calls slow down enough to timeout.

;;; Code:

(require 'test-helper)
(require 'gar-test-fake-llm)
(require 'gar-live-test-shared)
(require 'gptel-ollama)
(require 'url)

;; --- Configuration ---

(defvar gar-live-test--ollama-host "http://localhost:11434"
  "Where Ollama is expected to be running.")

(defvar gar-live-test--preferred-model "qwen2.5:7b-instruct"
  "Instruct model the live tests target.  Set to a model name that
`ollama list' reports.  Tests fall back to whatever the user's
currently active `gptel-model' is when this one is unavailable.")

;; (gar-live-test--request-timeout now lives in gar-live-test-shared)

;; --- Availability probe ---

(defun gar-live-test--ollama-available-p ()
  "Return non-nil when Ollama responds at the expected host."
  (condition-case _err
      (let ((url-request-method "GET")
            (url-show-status nil))
        (with-current-buffer (url-retrieve-synchronously
                              (concat gar-live-test--ollama-host "/api/tags")
                              t t 5)
          (goto-char (point-min))
          (search-forward "200 OK" nil t)))
    (error nil)))

(defun gar-live-test--installed-models ()
  "Return a list of model names currently installed in Ollama."
  (when (gar-live-test--ollama-available-p)
    (condition-case _err
        (with-current-buffer (url-retrieve-synchronously
                              (concat gar-live-test--ollama-host "/api/tags")
                              t t 5)
          (goto-char (point-min))
          (re-search-forward "^$" nil t)
          (let* ((body (buffer-substring-no-properties (point) (point-max)))
                 (parsed (json-parse-string body :object-type 'plist
                                                :array-type 'list)))
            (mapcar (lambda (m) (plist-get m :name))
                    (plist-get parsed :models))))
      (error nil))))

(defun gar-live-test--chosen-model ()
  "Return the model name the live tests should use.
Prefer `gar-live-test--preferred-model' when installed; else first
installed model."
  (let ((installed (gar-live-test--installed-models)))
    (or (car (cl-member gar-live-test--preferred-model installed
                        :test #'string=))
        (car installed))))

;; --- Backend setup ---

(defmacro gar-live-test-with-backend (&rest body)
  "Bind a minimal gptel Ollama backend pointing at the local server
and run BODY.  Restores prior `gptel-backend' / `gptel-model' values."
  (declare (indent 0))
  `(let* ((model-name (gar-live-test--chosen-model))
          (model-sym (and model-name (intern model-name)))
          (orig-backend gptel-backend)
          (orig-model gptel-model)
          (gptel-use-tools t))
     (unwind-protect
         (progn
           (setq gptel-backend
                 (gptel-make-ollama "live-test"
                   :host "localhost:11434"
                   :stream nil
                   :models (list model-sym)))
           (setq gptel-model model-sym)
           ,@body)
       (setq gptel-backend orig-backend
             gptel-model orig-model))))

;; --- Synchronous request helper now lives in `gar-live-test-shared'. ---

;; ============================================================================
;; The live tests
;; ============================================================================

;; --- 1. Smoke test: basic non-empty response ---

(ert-deftest gar-live-basic-response-nonempty ()
  "A minimal prompt returns a non-empty string from the instruct model."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
    (let ((response (gar-live-test--sync-request
                     "Reply with the word READY and nothing else.")))
      (should (stringp response))
      (should (> (length (string-trim response)) 0)))))

;; --- 2. Direct factual question ---

(ert-deftest gar-live-direct-question-contains-expected-token ()
  "A direct factual prompt produces a response that contains the expected
substring.  Loose match -- the model may add commentary."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
    (let ((response (gar-live-test--sync-request
                     "What is 2 + 2? Reply with just the number.")))
      (should (string-match-p "4" response)))))

;; --- 3. Planner-style prompt returns parseable JSON with steps array ---

(ert-deftest gar-live-planner-returns-json-with-steps ()
  "Feed the actual planner system prompt + a goal that requires real
work; assert the response parses as JSON with a non-empty steps array.

The goal is chosen so an instruct model that follows the planner
schema cannot legally return `steps: []' -- it has to either inspect
a file or produce a multi-step response.  Trivial goals like `say
hi' tempt the model to return empty steps, which is technically
schema-compliant but not what the loop expects in practice."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
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

(ert-deftest gar-live-reflection-returns-known-status ()
  "Send a reflection-shaped prompt and require the JSON :status field to
be one of the canonical loop states (continue/replan/done/failed)."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
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

;; --- 5. Full session end-to-end against the live model ---

(ert-deftest gar-live-full-session-produces-trajectory ()
  "Drive `gptel-agent-runtime-start' against the live LLM and assert a
trajectory was recorded for the session.

THIS IS THE SLOWEST TEST IN THE SUITE.  It chains three sequential
LLM calls (planner -> direct-response -> reflection) and, under
sustained Ollama load (i.e., when the rest of the live-test bundle
has already warmed-and-cooled the model 6+ times), each call can
run 60-80s -- exceeding any sane in-suite timeout.

Standalone it runs in ~45s and passes reliably.  Run explicitly
with `M-: (ert \"gar-live-full-session-produces-trajectory\")' or
opt in to slow tests by setting `GAR_RUN_SLOW=1' in the env."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-test-with-sandboxed-state
    (gar-live-test-with-backend
      (let* ((finalized nil)
             (sub-fn (lambda (_e) (setq finalized t))))
        (gptel-agent-runtime-subscribe 'session-finalized sub-fn)
        (unwind-protect
            (progn
              (gptel-agent-runtime-start
               "Say the word READY and nothing else.")
              ;; Wait up to 240s for the session-finalized event to fire.
              ;; The full session = planner + direct-response + reflection
              ;; ~3 LLM calls; ~45s under fresh Ollama, but the model can
              ;; respond more slowly under aggregate suite load (cold
              ;; cache, longer queues), so the deadline is generous.
              (let ((deadline (+ (float-time) 240)))
                (while (and (not finalized) (< (float-time) deadline))
                  (accept-process-output nil 0.1)))
              (should finalized)
              (should (>= (length gptel-agent-runtime--trajectories) 1))
              (let ((traj (car gptel-agent-runtime--trajectories)))
                (should (gptel-agent-runtime-trajectory-p traj))
                (should (memq (gptel-agent-runtime-trajectory-outcome traj)
                              '(success failure)))))
          ;; Best-effort unsubscribe.
          (let ((subs (alist-get 'session-finalized
                                 gptel-agent-runtime--event-subscribers)))
            (setf (alist-get 'session-finalized
                             gptel-agent-runtime--event-subscribers)
                  (cl-remove sub-fn subs :test #'eq))))))))

;; --- 6. Active model is honored ---

(ert-deftest gar-live-uses-the-configured-model ()
  "After binding `gptel-model' for the test, the active model symbol
matches the one we selected, and the backend points at the local
Ollama. Pure binding check -- no network request -- so this test
does not depend on Ollama having free resources after a long suite."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
    (should (symbolp gptel-model))
    (should (string= (gar-live-test--chosen-model)
                     (symbol-name gptel-model)))
    (should (gptel-ollama-p gptel-backend))
    (should (string= "live-test" (gptel-backend-name gptel-backend)))))

;; --- 7. Model declines to make stuff up about a non-question ---

(ert-deftest gar-live-instruction-following-short-answer ()
  "Instruction-following sanity: a `reply with just X' prompt yields a
response whose stripped length is close to X.  Loose enough to tolerate
trailing punctuation / explanation but tight enough to detect a model
that completely ignored the instruction."
  (skip-unless (gar-live-test--ollama-available-p))
  (skip-unless (getenv "GAR_RUN_SLOW"))
  (gar-live-test-with-backend
    (let* ((response (gar-live-test--sync-request
                      "Reply with exactly the single word: OK"))
           (clean (string-trim (downcase response))))
      (should (string-match-p "ok" clean))
      ;; A model that ignores the instruction tends to emit a paragraph;
      ;; allow up to 80 chars of leeway.
      (should (< (length clean) 80)))))

(provide 'gar-live-model-test)

;;; gar-live-model-test.el ends here
