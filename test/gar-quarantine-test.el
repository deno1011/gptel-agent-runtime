;;; gar-quarantine-test.el --- ERT tests for gar-quarantine -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(defun gar-quarantine-test--evidence (text source-type taint)
  "Create an evidence record for testing."
  (gptel-agent-runtime-make-evidence text source-type "test-source"
                                     :taint taint))

(defun gar-quarantine-test--step (url-arg)
  "Build a plan step whose :url argument is URL-ARG."
  (gptel-agent-runtime-plan-step-create
   :id "test-step"
   :title "test"
   :suggested-tool "web_fetch"
   :args (list :url url-arg)
   :risk 'safe
   :agent "researcher"))

(ert-deftest gar-quarantine-untrusted-web-evidence-is-quarantined ()
  "Fresh untrusted web evidence is reported as quarantined."
  (let* ((gptel-agent-runtime--evidence-trace nil)
         (gptel-agent-runtime--promoted-evidence-ids nil)
         (ev (gar-quarantine-test--evidence "secret-payload-abcdef0123456789"
                                            'web 'untrusted)))
    (should (gptel-agent-runtime-evidence-quarantined-p ev))
    (should (member ev (gptel-agent-runtime-quarantined-evidence)))))

(ert-deftest gar-quarantine-trusted-evidence-is-not-quarantined ()
  "Trusted evidence (user/runtime) is never quarantined regardless of source."
  (let* ((gptel-agent-runtime--evidence-trace nil)
         (gptel-agent-runtime--promoted-evidence-ids nil)
         (ev (gar-quarantine-test--evidence "hello" 'user 'trusted)))
    (should-not (gptel-agent-runtime-evidence-quarantined-p ev))))

(ert-deftest gar-quarantine-promote-clears-quarantine ()
  "promote-evidence removes the evidence from the quarantine set."
  (let* ((gptel-agent-runtime--evidence-trace nil)
         (gptel-agent-runtime--promoted-evidence-ids nil)
         (ev (gar-quarantine-test--evidence "promoted-payload-xyz12345" 'web 'untrusted)))
    (should (gptel-agent-runtime-evidence-quarantined-p ev))
    (gptel-agent-runtime-promote-evidence
     (gptel-agent-runtime-evidence-id ev))
    (should-not (gptel-agent-runtime-evidence-quarantined-p ev))
    (should-not (member ev (gptel-agent-runtime-quarantined-evidence)))))

(ert-deftest gar-quarantine-pre-flight-conflict-blocks-overlapping-arg ()
  "Pre-flight conflict triggers when a step argument verbatim matches quarantined text."
  (let* ((payload "leaked-secret-token-1234567890abcd")
         (gptel-agent-runtime--evidence-trace nil)
         (gptel-agent-runtime--promoted-evidence-ids nil)
         (gptel-agent-runtime-quarantine-pre-flight-enabled t)
         (_ev (gar-quarantine-test--evidence payload 'web 'untrusted))
         (step (gar-quarantine-test--step payload))
         (reason (gptel-agent-runtime--quarantine-conflict-p step)))
    (should (stringp reason))
    (should (string-match-p "quarantined evidence" reason))))

(ert-deftest gar-quarantine-pre-flight-no-conflict-when-disabled ()
  "Pre-flight returns nil when the feature is disabled even if text overlaps."
  (let* ((payload "another-leaked-payload-zzz0987654321")
         (gptel-agent-runtime--evidence-trace nil)
         (gptel-agent-runtime--promoted-evidence-ids nil)
         (gptel-agent-runtime-quarantine-pre-flight-enabled nil)
         (_ev (gar-quarantine-test--evidence payload 'web 'untrusted))
         (step (gar-quarantine-test--step payload)))
    (should-not (gptel-agent-runtime--quarantine-conflict-p step))))

(ert-deftest gar-quarantine-rule-text-has-load-bearing-markers ()
  "The quarantine rule string contains the load-bearing markers prompts rely on."
  (let ((rule (gptel-agent-runtime--quarantine-rule-text)))
    (should (string-match-p "QUARANTINE RULE" rule))
    (should (string-match-p "MUST NOT" rule))
    (should (string-match-p "promote-evidence" rule))))

(provide 'gar-quarantine-test)

;;; gar-quarantine-test.el ends here
