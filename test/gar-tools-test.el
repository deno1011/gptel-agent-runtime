;;; gar-tools-test.el --- ERT tests for gar-tools -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- registry round-trip ---

(ert-deftest gar-tools-register-and-find-round-trip ()
  "register-tool stores metadata that find-tool retrieves by name."
  (let ((gptel-agent-runtime-tool-registry nil))
    (gptel-agent-runtime-register-tool
     "test_probe" 'read 'safe "test probe tool"
     :caps '(read-fs))
    (let ((tool (gptel-agent-runtime-find-tool "test_probe")))
      (should tool)
      (should (eq 'read (gptel-agent-runtime-tool-category tool)))
      (should (eq 'safe (gptel-agent-runtime-tool-risk tool))))))

(ert-deftest gar-tools-find-tool-unknown-returns-nil ()
  "find-tool returns nil for a name that was never registered."
  (let ((gptel-agent-runtime-tool-registry nil))
    (should-not (gptel-agent-runtime-find-tool "no-such-tool"))))

(ert-deftest gar-tools-find-tool-accepts-symbol ()
  "find-tool normalizes symbol input to a string."
  (let ((gptel-agent-runtime-tool-registry nil))
    (gptel-agent-runtime-register-tool "sym_probe" 'read 'safe "x")
    (should (gptel-agent-runtime-find-tool 'sym_probe))))

(ert-deftest gar-tools-by-category-filters ()
  "tools-by-category returns only tools registered in that category."
  (let ((gptel-agent-runtime-tool-registry nil))
    (gptel-agent-runtime-register-tool "a_read" 'read 'safe "a")
    (gptel-agent-runtime-register-tool "b_read" 'read 'safe "b")
    (gptel-agent-runtime-register-tool "c_write" 'write 'write "c")
    (let ((reads (gptel-agent-runtime-tools-by-category 'read)))
      (should (= 2 (length reads))))))

;; --- result-ok / result-error ---

(ert-deftest gar-tools-result-ok-creates-success-action-result ()
  "result-ok builds an action-result with :status ok and the output."
  (let ((r (gptel-agent-runtime-result-ok :tool "t" :output "hello")))
    (should (gptel-agent-runtime-action-result-p r))
    (should (eq 'ok (gptel-agent-runtime-action-result-status r)))
    (should (string= "hello" (gptel-agent-runtime-action-result-output r)))))

(ert-deftest gar-tools-result-error-creates-error-action-result ()
  "result-error builds an action-result with :status error and an :error message."
  (let ((r (gptel-agent-runtime-result-error :tool "t" :error "boom")))
    (should (gptel-agent-runtime-action-result-p r))
    (should (eq 'error (gptel-agent-runtime-action-result-status r)))
    (should (string= "boom" (gptel-agent-runtime-action-result-error r)))))

;; --- tool-invention safety walk ---

(ert-deftest gar-tools-safe-form-violations-allows-whitelisted ()
  "--safe-form-violations returns nil for forms using only allowed symbols."
  (should-not
   (gptel-agent-runtime--safe-form-violations
    '(defun foo (x) (+ x 1)))))

(ert-deftest gar-tools-safe-form-violations-flags-delete-file ()
  "--safe-form-violations rejects forms that call delete-file."
  (let ((vios (gptel-agent-runtime--safe-form-violations
               '(defun bad () (delete-file "/etc/passwd")))))
    (should vios)))

(ert-deftest gar-tools-safe-form-violations-flags-shell-command ()
  "--safe-form-violations rejects forms that call shell-command."
  (let ((vios (gptel-agent-runtime--safe-form-violations
               '(defun bad () (shell-command "rm -rf /")))))
    (should vios)))

(ert-deftest gar-tools-safe-form-violations-flags-eval ()
  "--safe-form-violations rejects forms that call `eval'."
  (let ((vios (gptel-agent-runtime--safe-form-violations
               '(defun bad () (eval form)))))
    (should vios)))

;; --- arg-schema backfill smoke ---

(ert-deftest gar-tools-arg-schema-backfill-covers-mutation-tools ()
  "The 8 high-risk native tools are registered with an :arg-schema after package load."
  (dolist (name '("run_elisp" "execute_code" "write_file" "write_org_file"
                  "add_todo" "change_todo_state" "set_deadline" "add_tag"))
    (let ((tool (gptel-agent-runtime-find-tool name)))
      (should tool)
      (should (gptel-agent-runtime-tool-arg-schema tool)))))

(ert-deftest gar-tools-arg-schema-rejects-non-iso-date-on-set-deadline ()
  "The set_deadline schema enforces YYYY-MM-DD via :pattern."
  (let* ((tool (gptel-agent-runtime-find-tool "set_deadline"))
         (schema (gptel-agent-runtime-tool-arg-schema tool))
         (errs (gptel-agent-runtime-validate-args
                '(:file "todo.org" :heading "x" :date "tomorrow") schema)))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p ":pattern" e)) errs))))

(ert-deftest gar-tools-arg-schema-execute-code-enum-rejects-unknown-language ()
  "The execute_code schema enforces the language enum."
  (let* ((tool (gptel-agent-runtime-find-tool "execute_code"))
         (schema (gptel-agent-runtime-tool-arg-schema tool))
         (errs (gptel-agent-runtime-validate-args
                '(:language "ruby" :code "puts 1") schema)))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p ":enum" e)) errs))))

(provide 'gar-tools-test)

;;; gar-tools-test.el ends here
