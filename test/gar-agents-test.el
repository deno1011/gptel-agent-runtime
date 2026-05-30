;;; gar-agents-test.el --- ERT tests for gar-agents -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- PR 12: workspace context groups TODOs by file ---

(ert-deftest gar-agents-workspace-context-groups-todos-by-file ()
  "`build-workspace-context' renders TODO entries grouped by state and
then by file, so a model trying to act on a specific entry sees which
file holds it.  Pre-PR 12 the file information was stripped and a
small model had no path from `set deadline on Hello2' to `look in
~/org/reminders.org'."
  (cl-letf (((symbol-function 'gptel-agent-runtime-collect-org-todos)
             (lambda (&rest _ignored)
               (list (list :state "TODO" :heading "Hello2"
                           :file "~/org/reminders.org"
                           :deadline nil :tags "")
                     (list :state "TODO" :heading "Einkaufsliste"
                           :file "~/org/reminders.org"
                           :deadline nil :tags "")
                     (list :state "TODO" :heading "Refactor router"
                           :file "~/emacs/data/org/inbox.org"
                           :deadline "2026-06-01" :tags "code")))))
    (let ((ctx (gptel-agent-runtime-build-workspace-context)))
      (should (stringp ctx))
      (should (string-match-p "TODO summary" ctx))
      ;; Each file appears as a sub-header inside the [TODO] block.
      (should (string-match-p "in ~/org/reminders.org:" ctx))
      (should (string-match-p "in ~/emacs/data/org/inbox.org:" ctx))
      ;; And the headings live under those file groups.
      (should (string-match-p "Hello2" ctx))
      (should (string-match-p "Einkaufsliste" ctx))
      (should (string-match-p "Refactor router" ctx))
      ;; Deadline + tags still render.
      (should (string-match-p "due: 2026-06-01" ctx))
      (should (string-match-p ":code:" ctx)))))

(ert-deftest gar-agents-workspace-context-handles-missing-file-gracefully ()
  "Entries with a nil :file slot fall under `(unknown file)' rather
than crashing the renderer."
  (cl-letf (((symbol-function 'gptel-agent-runtime-collect-org-todos)
             (lambda (&rest _ignored)
               (list (list :state "TODO" :heading "Orphan"
                           :file nil :deadline nil :tags "")))))
    (let ((ctx (gptel-agent-runtime-build-workspace-context)))
      (should (stringp ctx))
      (should (string-match-p "Orphan" ctx))
      (should (string-match-p "(unknown file)" ctx)))))

(provide 'gar-agents-test)

;;; gar-agents-test.el ends here
