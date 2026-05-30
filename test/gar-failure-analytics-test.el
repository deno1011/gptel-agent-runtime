;;; gar-failure-analytics-test.el --- ERT tests for gar-failure-analytics -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- reason classification ---

(ert-deftest gar-failure-analytics-classify-not-found ()
  (should (string=
           "not found"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Heading not found in reminders.org: Hello2"))))

(ert-deftest gar-failure-analytics-classify-ambiguous ()
  (should (string=
           "ambiguous heading"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Ambiguous: 2 headings match 'Buy milk'."))))

(ert-deftest gar-failure-analytics-classify-policy-denied ()
  (should (string=
           "policy denied"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Action denied by policy: capability shell-exec missing"))))

(ert-deftest gar-failure-analytics-classify-void ()
  (should (string=
           "void function/symbol"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Symbol's function definition is void: my/missing-fn"))))

(ert-deftest gar-failure-analytics-classify-incomplete ()
  (should (string=
           "incomplete answer"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Your previous response only included 5 of 66 items from the prior tool result."))))

(ert-deftest gar-failure-analytics-classify-empty-or-nil ()
  (should (string= "other"
                   (gptel-agent-runtime--failure-analytics-classify-reason "")))
  (should (string= "other"
                   (gptel-agent-runtime--failure-analytics-classify-reason nil))))

(ert-deftest gar-failure-analytics-classify-other ()
  "Anything that doesn't match a known pattern falls to `other'."
  (should (string=
           "other"
           (gptel-agent-runtime--failure-analytics-classify-reason
            "Some genuinely unexpected condition flag"))))

;; --- aggregation from verdicts ---

(ert-deftest gar-failure-analytics-failures-from-verdicts ()
  "The verdict reader filters to `:passed nil' entries and labels
each with classified reason + tool."
  (let ((gptel-agent-runtime--last-verifier-verdicts
         (list
          (cons "2026-05-30T10:00:00"
                (list :passed nil :tool "set_deadline"
                      :reason "Heading not found in reminders.org"
                      :step "Set deadline"))
          (cons "2026-05-30T10:01:00"
                (list :passed t :tool "read_file"
                      :reason "All good"
                      :step "Read"))
          (cons "2026-05-30T10:02:00"
                (list :passed nil :tool "change_todo_state"
                      :reason "Ambiguous: 2 headings match"
                      :step "Mark done")))))
    (let ((failures (gptel-agent-runtime--failure-analytics-failures-from-verdicts)))
      (should (= 2 (length failures)))
      (let ((reasons (mapcar (lambda (f) (plist-get f :reason)) failures))
            (tools (mapcar (lambda (f) (plist-get f :tool)) failures)))
        (should (member "not found" reasons))
        (should (member "ambiguous heading" reasons))
        (should (member "set_deadline" tools))
        (should (member "change_todo_state" tools))))))

;; --- top counts ---

(ert-deftest gar-failure-analytics-top-counts-by-tool ()
  (let* ((failures (list (list :tool "a") (list :tool "a")
                         (list :tool "b") (list :tool "c")
                         (list :tool "a")))
         (top (gptel-agent-runtime--failure-analytics-top-counts
               :tool failures)))
    (should (equal '("a" . 3) (car top)))
    (should (= 3 (length top)))))

(ert-deftest gar-failure-analytics-top-counts-respects-top-n ()
  (let* ((gptel-agent-runtime-failure-analytics-top-n 2)
         (failures (cl-loop for i from 0 below 10
                            collect (list :tool (format "tool-%d" i))))
         (top (gptel-agent-runtime--failure-analytics-top-counts
               :tool failures)))
    (should (= 2 (length top)))))

;; --- summary rendering ---

(ert-deftest gar-failure-analytics-summary-empty-message ()
  "When there are no failures, the summary is the `(no failures...)' line."
  (let ((gptel-agent-runtime--last-verifier-verdicts nil)
        (gptel-agent-runtime--trajectories nil))
    (let ((s (gptel-agent-runtime-failure-analytics-summary)))
      (should (string-match-p "no failures recorded yet" s)))))

(ert-deftest gar-failure-analytics-summary-renders-counts ()
  "When there ARE failures, the summary includes tool + reason
sections AND the M-x report hint."
  (let ((gptel-agent-runtime--last-verifier-verdicts
         (list (cons "ts"
                     (list :passed nil :tool "set_deadline"
                           :reason "Heading not found"
                           :step "x"))))
        (gptel-agent-runtime--trajectories nil))
    (let ((s (gptel-agent-runtime-failure-analytics-summary)))
      (should (string-match-p "Total recent failures: 1" s))
      (should (string-match-p "set_deadline" s))
      (should (string-match-p "not found" s))
      (should (string-match-p
               "M-x gptel-agent-runtime-failure-report" s)))))

;; --- report buffer ---

(ert-deftest gar-failure-analytics-report-creates-readonly-buffer ()
  (let ((gptel-agent-runtime--last-verifier-verdicts nil)
        (gptel-agent-runtime--trajectories nil)
        (buf-name "*gar-failure-test-buf*"))
    (let ((gptel-agent-runtime-failure-report-buffer-name buf-name))
      (unwind-protect
          (progn
            (gptel-agent-runtime-failure-report)
            (let ((buf (get-buffer buf-name)))
              (should (bufferp buf))
              (with-current-buffer buf
                (should buffer-read-only)
                (should (> (buffer-size) 20)))))
        (when (get-buffer buf-name) (kill-buffer buf-name))))))

(provide 'gar-failure-analytics-test)

;;; gar-failure-analytics-test.el ends here
