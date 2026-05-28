;;; gar-validator-test.el --- ERT tests for gar-validator -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- type checking ---

(ert-deftest gar-validator-string-type-passes ()
  (should-not (gptel-agent-runtime-validate-args
               "hello" '(:type string))))

(ert-deftest gar-validator-string-type-rejects-integer ()
  (let ((errs (gptel-agent-runtime-validate-args 42 '(:type string))))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p "expected type string" e))
                     errs))))

(ert-deftest gar-validator-integer-type-rejects-float ()
  (should (gptel-agent-runtime-validate-args 3.14 '(:type integer))))

(ert-deftest gar-validator-type-list-allows-union ()
  "A :type list-of-symbols accepts a value matching any listed type."
  (should-not (gptel-agent-runtime-validate-args 42 '(:type (string integer))))
  (should-not (gptel-agent-runtime-validate-args "hi" '(:type (string integer)))))

(ert-deftest gar-validator-type-any-accepts-everything ()
  (should-not (gptel-agent-runtime-validate-args nil '(:type any)))
  (should-not (gptel-agent-runtime-validate-args '(1 2 3) '(:type any))))

;; --- enum ---

(ert-deftest gar-validator-enum-passes-on-allowed-value ()
  (should-not (gptel-agent-runtime-validate-args
               "red" '(:enum ("red" "green" "blue")))))

(ert-deftest gar-validator-enum-rejects-unlisted ()
  (let ((errs (gptel-agent-runtime-validate-args
               "purple" '(:enum ("red" "green" "blue")))))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p ":enum" e)) errs))))

;; --- string bounds + pattern ---

(ert-deftest gar-validator-min-length-rejects-empty ()
  (should (gptel-agent-runtime-validate-args
           "" '(:type string :min-length 1))))

(ert-deftest gar-validator-max-length-rejects-long ()
  (should (gptel-agent-runtime-validate-args
           "way too long" '(:type string :max-length 4))))

(ert-deftest gar-validator-pattern-rejects-mismatch ()
  (should (gptel-agent-runtime-validate-args
           "abc" '(:type string :pattern "\\`[0-9]+\\'")))
  (should-not (gptel-agent-runtime-validate-args
               "12345" '(:type string :pattern "\\`[0-9]+\\'"))))

;; --- numeric bounds ---

(ert-deftest gar-validator-minimum-rejects-below ()
  (should (gptel-agent-runtime-validate-args
           -1 '(:type integer :minimum 0))))

(ert-deftest gar-validator-maximum-rejects-above ()
  (should (gptel-agent-runtime-validate-args
           1000 '(:type integer :maximum 100))))

;; --- objects: required, properties, additional-properties ---

(ert-deftest gar-validator-object-valid-args-passes ()
  (let ((schema '(:type object
                  :properties (:path (:type string :min-length 1)
                               :max-bytes (:type integer :minimum 0))
                  :required (:path))))
    (should-not (gptel-agent-runtime-validate-args
                 '(:path "/tmp/x" :max-bytes 100) schema))))

(ert-deftest gar-validator-object-missing-required-key-flagged ()
  (let* ((schema '(:type object
                   :properties (:path (:type string))
                   :required (:path)))
         (errs (gptel-agent-runtime-validate-args '() schema)))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p "missing required key :path" e))
                     errs))
    ;; Should NOT also flag a redundant type-mismatch for the missing key.
    (should-not (cl-some (lambda (e) (string-match-p "expected type" e))
                         errs))))

(ert-deftest gar-validator-additional-properties-nil-flags-unknown ()
  (let* ((schema '(:type object
                   :properties (:path (:type string))
                   :additional-properties nil))
         (errs (gptel-agent-runtime-validate-args
                '(:path "/tmp/x" :sneaky t) schema)))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p "unknown property :sneaky" e))
                     errs))))

(ert-deftest gar-validator-additional-properties-default-allows-extra ()
  (let ((schema '(:type object :properties (:path (:type string)))))
    (should-not (gptel-agent-runtime-validate-args
                 '(:path "/tmp/x" :extra "ignored") schema))))

;; --- objects: accepts alist form too ---

(ert-deftest gar-validator-accepts-alist-form ()
  (let ((schema '(:type object :properties (:path (:type string))
                  :required (:path))))
    (should-not (gptel-agent-runtime-validate-args
                 '((:path . "/tmp/x")) schema))))

;; --- arrays ---

(ert-deftest gar-validator-array-min-items-rejects-empty ()
  (should (gptel-agent-runtime-validate-args
           '() '(:type array :min-items 1))))

(ert-deftest gar-validator-array-items-schema-checks-each ()
  (let* ((schema '(:type array :items (:type string)))
         (errs (gptel-agent-runtime-validate-args
                '("ok" 42 "also-ok") schema)))
    (should errs)
    (should (cl-some (lambda (e) (string-match-p "/1:" e)) errs))))

;; --- args-valid-p convenience ---

(ert-deftest gar-validator-args-valid-p-boolean ()
  (should (gptel-agent-runtime-args-valid-p
           '(:k "v") '(:type object :properties (:k (:type string)))))
  (should-not (gptel-agent-runtime-args-valid-p
               '(:k 42) '(:type object :properties (:k (:type string))))))

(provide 'gar-validator-test)

;;; gar-validator-test.el ends here
