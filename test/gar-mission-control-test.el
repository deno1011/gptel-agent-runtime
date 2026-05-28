;;; gar-mission-control-test.el --- ERT tests for gar-mission-control -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(ert-deftest gar-mission-control-dashboard-renders-nine-sections ()
  "`M-x gptel-agent-runtime-mission-control' renders the 9 expected sections."
  (gptel-agent-runtime-mission-control)
  (with-current-buffer gptel-agent-runtime-mission-control-buffer-name
    (let ((sections '("Substrate" "Policy" "Recent events" "Recent evidence"
                      "Quarantine" "Injection canaries" "Skeptic"
                      "Exploration & learning"
                      "Agents / capability allowlists")))
      (dolist (s sections)
        (should (save-excursion
                  (goto-char (point-min))
                  (re-search-forward (concat "=== " (regexp-quote s) " ===")
                                     nil t)))))))

(ert-deftest gar-tool-policy-editor-opens-and-rows-match-manifest ()
  "Editor opens with one row per known tool (manifest union default + user)."
  (let ((gptel-agent-runtime-tool-policy nil))
    (gptel-agent-runtime-tool-policy-editor)
    (with-current-buffer gptel-agent-runtime-tool-policy-editor-buffer-name
      (let ((rows (gptel-agent-runtime--tool-policy-rows))
            (known (gptel-agent-runtime--tool-policy-known-tools)))
        (should (= (length rows) (length known)))
        (should (= 6 (length tabulated-list-format)))))))

(ert-deftest gar-tool-policy-cycle-confirm-flips-nil-to-write ()
  "Cycling :confirm from nil produces (:confirm write)."
  (let ((gptel-agent-runtime-tool-policy nil))
    (gptel-agent-runtime-tool-policy-editor)
    (with-current-buffer gptel-agent-runtime-tool-policy-editor-buffer-name
      (goto-char (point-min))
      (when (search-forward "execute_code" nil t)
        (beginning-of-line)
        (gptel-agent-runtime-tool-policy-cycle-confirm)
        (should (equal '(:confirm write)
                       (cdr (assoc "execute_code"
                                   gptel-agent-runtime-tool-policy))))))))

(ert-deftest gar-tool-policy-cycle-default-toggles-allow-deny ()
  "Cycling :default round-trips through allow → deny → allow."
  (let ((gptel-agent-runtime-tool-policy nil))
    (gptel-agent-runtime-tool-policy-editor)
    (with-current-buffer gptel-agent-runtime-tool-policy-editor-buffer-name
      (goto-char (point-min))
      (when (search-forward "run_elisp" nil t)
        (beginning-of-line)
        ;; Starting state: no user override (no :default key).
        (gptel-agent-runtime-tool-policy-cycle-default)
        (should (eq 'allow
                    (plist-get (cdr (assoc "run_elisp"
                                           gptel-agent-runtime-tool-policy))
                               :default)))
        (gptel-agent-runtime-tool-policy-cycle-default)
        (should (eq 'deny
                    (plist-get (cdr (assoc "run_elisp"
                                           gptel-agent-runtime-tool-policy))
                               :default)))
        (gptel-agent-runtime-tool-policy-cycle-default)
        (should (eq 'allow
                    (plist-get (cdr (assoc "run_elisp"
                                           gptel-agent-runtime-tool-policy))
                               :default)))))))

(ert-deftest gar-tool-policy-reset-line-removes-user-override ()
  "Reset removes the tool's user entry entirely and falls back to default layer."
  (let ((gptel-agent-runtime-tool-policy
         '(("execute_code" . (:confirm always :taint untrusted)))))
    (gptel-agent-runtime-tool-policy-editor)
    (with-current-buffer gptel-agent-runtime-tool-policy-editor-buffer-name
      (goto-char (point-min))
      (when (search-forward "execute_code" nil t)
        (beginning-of-line)
        (gptel-agent-runtime-tool-policy-reset-line)
        (should-not (assoc "execute_code"
                           gptel-agent-runtime-tool-policy))
        (should (memq (gptel-agent-runtime--tool-policy-source "execute_code")
                      '(default preset)))))))

(ert-deftest gar-tool-policy-strip-key-empties-plist ()
  "Stripping the only key from a single-key plist returns nil (no empty stub)."
  (should-not (gptel-agent-runtime--tool-policy-strip-key
               '(:confirm always) :confirm)))

(ert-deftest gar-tool-policy-strip-key-preserves-other-keys ()
  "Stripping one key from a multi-key plist preserves the others."
  (should (equal '(:taint trusted)
                 (gptel-agent-runtime--tool-policy-strip-key
                  '(:confirm always :taint trusted) :confirm))))

(provide 'gar-mission-control-test)

;;; gar-mission-control-test.el ends here
