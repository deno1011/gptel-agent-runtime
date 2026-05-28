;;; gar-substrate-test.el --- ERT tests for gar-substrate -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

(ert-deftest gar-substrate-advance-tick-monotone ()
  "`--advance-tick' increments the counter by 1 each call."
  (let* ((gptel-agent-runtime-tick-counter 0)
         (gptel-agent-runtime-event-log nil)
         (gptel-agent-runtime--event-subscribers nil))
    (gptel-agent-runtime--advance-tick 'test)
    (should (= 1 gptel-agent-runtime-tick-counter))
    (gptel-agent-runtime--advance-tick 'test)
    (should (= 2 gptel-agent-runtime-tick-counter))))

(ert-deftest gar-substrate-subscribe-and-dispatch-round-trip ()
  "subscribe + emit-event delivers the event to the handler."
  (let* ((gptel-agent-runtime--event-subscribers nil)
         (received nil)
         (handler (lambda (ev) (setq received ev))))
    (gptel-agent-runtime-subscribe 'test-type handler)
    (gptel-agent-runtime-emit-event 'test-type :source "t" :payload '(:k 1))
    (should received)
    (should (eq 'test-type (gptel-agent-runtime-event-type received)))
    (gptel-agent-runtime-unsubscribe 'test-type handler)))

(ert-deftest gar-substrate-dispatch-isolates-failing-subscriber ()
  "A subscriber that signals does not prevent other subscribers from firing."
  (let* ((gptel-agent-runtime--event-subscribers nil)
         (received nil)
         (good (lambda (ev) (push 'good received)))
         (bad (lambda (_ev) (error "boom")))
         (good2 (lambda (ev) (push 'good2 received))))
    (gptel-agent-runtime-subscribe 'isolate-test good)
    (gptel-agent-runtime-subscribe 'isolate-test bad)
    (gptel-agent-runtime-subscribe 'isolate-test good2)
    (gptel-agent-runtime-emit-event 'isolate-test :source "t")
    (should (member 'good received))
    (should (member 'good2 received))))

(ert-deftest gar-substrate-make-evidence-assigns-id-and-records-trace ()
  "make-evidence stamps an id, timestamp, and pushes onto --evidence-trace."
  (let* ((gptel-agent-runtime-tick-counter 5)
         (gptel-agent-runtime--evidence-trace nil)
         (ev (gptel-agent-runtime-make-evidence "hello" 'tool-result
                                                "tool-x")))
    (should (gptel-agent-runtime-evidence-p ev))
    (should (stringp (gptel-agent-runtime-evidence-id ev)))
    (should (stringp (gptel-agent-runtime-evidence-text ev)))
    (should (eq 'tool-result (gptel-agent-runtime-evidence-source-type ev)))
    (should (member ev gptel-agent-runtime--evidence-trace))))

(ert-deftest gar-substrate-make-evidence-default-taint-untrusted-for-web ()
  "Web/tool-result/file evidence defaults to untrusted; user defaults to trusted."
  (let* ((gptel-agent-runtime--evidence-trace nil)
         (ev-web (gptel-agent-runtime-make-evidence "x" 'web "u"))
         (ev-user (gptel-agent-runtime-make-evidence "y" 'user "u")))
    (should (eq 'untrusted (gptel-agent-runtime-evidence-taint ev-web)))
    (should (eq 'trusted (gptel-agent-runtime-evidence-taint ev-user)))))

(ert-deftest gar-substrate-evidence-trace-bounded ()
  "--evidence-trace is capped (300 entries default) so it does not grow unbounded."
  (let ((gptel-agent-runtime--evidence-trace nil))
    (dotimes (i 350)
      (gptel-agent-runtime-make-evidence (format "ev-%d" i) 'tool-result "t"))
    (should (<= (length gptel-agent-runtime--evidence-trace) 300))))

(ert-deftest gar-substrate-shorten-truncates ()
  "`--shorten' clips long strings (appending an ellipsis) and leaves short ones alone."
  (let ((short (gptel-agent-runtime--shorten "abcdefghij" 5)))
    (should (string-prefix-p "abcde" short))
    (should (string-suffix-p "..." short)))
  (should (string= "hi" (gptel-agent-runtime--shorten "hi" 50)))
  (should (stringp (gptel-agent-runtime--shorten nil 5))))

(ert-deftest gar-substrate-state-header-includes-schema-version ()
  "Persisted state header is a plist marked with the schema version."
  (let ((header (gptel-agent-runtime--state-header)))
    (should (listp header))
    (should (plist-get header :gptel-agent-runtime-state))
    (should (= gptel-agent-runtime-state-schema-version
               (plist-get header :schema)))
    (should (gptel-agent-runtime--state-header-p header))))

(provide 'gar-substrate-test)

;;; gar-substrate-test.el ends here
