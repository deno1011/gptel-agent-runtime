;;; run-tests.el --- batch entrypoint for the gar-* ERT smoke tests -*- lexical-binding: t; -*-

;; Discovers every `gar-*-test.el' in this directory, loads each one
;; (each pulls in `test-helper' which loads the package), and runs
;; `ert-run-tests-batch-and-exit'.
;;
;; Invocation:
;;
;;     emacs -Q --batch -l test/run-tests.el

;;; Code:

(let ((dir (file-name-directory
            (or load-file-name buffer-file-name))))
  (add-to-list 'load-path dir)
  (dolist (file (directory-files dir t "\\`gar-.*-test\\.el\\'"))
    (load file nil 'nomessage)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
