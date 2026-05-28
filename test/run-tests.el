;;; run-tests.el --- batch entrypoint for the gar-* ERT smoke tests -*- lexical-binding: t; -*-

;; Discovers every `gar-*-test.el' in this directory, loads each one
;; (each pulls in `test-helper' which loads the package), and runs
;; `ert-run-tests-batch-and-exit'.
;;
;; Invocation:
;;
;;     emacs -Q --batch -l test/run-tests.el

;;; Code:

;; Defensive: in batch mode, always test against the freshly tangled .el
;; sources. Delete any byte-compiled .elc files in the package root and
;; test directory before loading. `test-helper' additionally sets
;; `load-prefer-newer' to t, which guards against the inverse case (a
;; .elc that's older than its .el on disk).
(let* ((test-dir (file-name-directory
                  (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name test-dir))))
  (dolist (dir (list root test-dir))
    (dolist (elc (directory-files dir t "\\.elc\\'"))
      (delete-file elc)))
  (add-to-list 'load-path test-dir)
  (dolist (file (directory-files test-dir t "\\`gar-.*-test\\.el\\'"))
    (load file nil 'nomessage)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
