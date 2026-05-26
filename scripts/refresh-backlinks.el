;;; refresh-backlinks.el --- regenerate "Required by" footers in gar-* org modules -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime.
;;
;; Scans each tangled gar-*.el in the package root for `(require 'gar-...)`
;; forms (excluding `(require 'gar-... nil t)' soft requires, which are
;; tolerated-missing and do not constitute a real dependency edge).
;;
;; For each module, computes the set of OTHER modules that require it, and
;; rewrites the "Required by" section between the
;;
;;     <!-- gar:auto-backlinks:start -->
;;     <!-- gar:auto-backlinks:end -->
;;
;; sentinels in the corresponding gar-NAME.org. Idempotent: re-running with
;; no change in (require) forms produces no diff.
;;
;; Invocation:
;;
;;     emacs -Q --batch -l scripts/refresh-backlinks.el \
;;       -f gar-refresh-backlinks-and-exit

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar gar-refresh-backlinks-root
  (or (and load-file-name (file-name-directory
                           (directory-file-name
                            (file-name-directory load-file-name))))
      default-directory)
  "Directory holding the gar-*.org/.el module files.")

(defconst gar-refresh-backlinks-start-marker
  "<!-- gar:auto-backlinks:start -->")

(defconst gar-refresh-backlinks-end-marker
  "<!-- gar:auto-backlinks:end -->")

(defun gar-refresh-backlinks--module-name (file)
  "Return the module name (string, e.g. \"gar-context\") for FILE."
  (file-name-base file))

(defun gar-refresh-backlinks--list-module-elisp-files ()
  "Return the list of gar-*.el module files in the package root.
Excludes the master `gptel-agent-runtime.el' entrypoint."
  (let ((root gar-refresh-backlinks-root))
    (cl-remove-if-not
     (lambda (f) (string-match-p "^gar-" (file-name-nondirectory f)))
     (directory-files root t "\\`gar-[^.]*\\.el\\'"))))

(defun gar-refresh-backlinks--list-module-org-files ()
  "Return the list of gar-*.org module files in the package root."
  (let ((root gar-refresh-backlinks-root))
    (cl-remove-if-not
     (lambda (f) (string-match-p "^gar-" (file-name-nondirectory f)))
     (directory-files root t "\\`gar-[^.]*\\.org\\'"))))

(defun gar-refresh-backlinks--scan-requires (elisp-file)
  "Return the list of `gar-*' feature symbols hard-required by ELISP-FILE.
Soft requires (i.e. `(require 'gar-foo nil t)') are excluded."
  (let (results)
    (with-temp-buffer
      (insert-file-contents elisp-file)
      (goto-char (point-min))
      (while (re-search-forward
              "(require[ \t\n]+'\\(gar-[^ \t\n)]+\\)" nil t)
        (let* ((sym (match-string 1))
               ;; Look at what follows: if it's a NOERROR (t) arg, skip.
               (after (save-excursion
                        (goto-char (match-end 0))
                        (skip-chars-forward " \t\n")
                        (when (looking-at "[^)]")
                          (buffer-substring-no-properties
                           (point)
                           (min (point-max) (+ (point) 20)))))))
          (unless (and after (string-prefix-p "nil t" (string-trim after)))
            (push (intern sym) results)))))
    (cl-remove-duplicates (nreverse results))))

(defun gar-refresh-backlinks--build-graph ()
  "Return an alist mapping each module symbol to the list of modules requiring it."
  (let ((files (gar-refresh-backlinks--list-module-elisp-files))
        (incoming (make-hash-table :test 'eq)))
    (dolist (file files)
      (let ((src (intern (gar-refresh-backlinks--module-name file))))
        (dolist (req (gar-refresh-backlinks--scan-requires file))
          (push src (gethash req incoming nil)))))
    (let (alist)
      (maphash (lambda (k v) (push (cons k (nreverse v)) alist)) incoming)
      alist)))

(defun gar-refresh-backlinks--render-section (module requirers)
  "Return the Org text for the auto-backlinks section of MODULE.
REQUIRERS is the list of module symbols that require MODULE."
  (concat
   gar-refresh-backlinks-start-marker "\n"
   "* Required by\n\n"
   (if (null requirers)
       "  (no other modules require this one yet)\n"
     (concat "This module is required by:\n"
             (mapconcat
              (lambda (r)
                (format "- [[file:%s.org][%s]]" r r))
              requirers
              "\n")
             "\n"))
   gar-refresh-backlinks-end-marker))

(defun gar-refresh-backlinks--rewrite-section (org-file requirers)
  "Rewrite the auto-backlinks section of ORG-FILE to reflect REQUIRERS.
If no markers exist, append the section to the end of the file."
  (with-temp-buffer
    (insert-file-contents org-file)
    (let* ((module (intern (gar-refresh-backlinks--module-name org-file)))
           (new (gar-refresh-backlinks--render-section module requirers))
           (orig (buffer-string)))
      (goto-char (point-min))
      (if (re-search-forward
           (regexp-quote gar-refresh-backlinks-start-marker) nil t)
          (let ((start (match-beginning 0)))
            (if (re-search-forward
                 (regexp-quote gar-refresh-backlinks-end-marker) nil t)
                (let ((end (match-end 0)))
                  (delete-region start end)
                  (goto-char start)
                  (insert new))
              (error "%s: start marker found but end marker missing" org-file)))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "\n" new "\n"))
      (let ((updated (buffer-string)))
        (unless (string= orig updated)
          (write-region (point-min) (point-max) org-file nil 'silent)
          (message "gar-refresh-backlinks: updated %s" org-file))))))

(defun gar-refresh-backlinks ()
  "Refresh `Required by' backlinks across all gar-*.org modules."
  (interactive)
  (let* ((org-files (gar-refresh-backlinks--list-module-org-files))
         (graph (gar-refresh-backlinks--build-graph)))
    (dolist (org-file org-files)
      (let* ((module (intern (gar-refresh-backlinks--module-name org-file)))
             (requirers (cdr (assoc module graph))))
        (gar-refresh-backlinks--rewrite-section org-file requirers)))
    (message "gar-refresh-backlinks: processed %d module(s)" (length org-files))))

(defun gar-refresh-backlinks-and-exit ()
  "Batch entrypoint: refresh backlinks, then exit Emacs."
  (gar-refresh-backlinks)
  (kill-emacs 0))

(provide 'refresh-backlinks)

;;; refresh-backlinks.el ends here
