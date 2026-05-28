;;; refresh-dep-graph.el --- regenerate docs/dependency-graph.svg from (require) edges -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime.
;;
;; Scans `gptel-agent-runtime.el' and every tangled `gar-*.el' in the package
;; root for hard `(require 'gar-...)' forms (excluding `nil t' soft requires),
;; emits a DOT graph where an edge A -> B means "A (require)s B", and shells
;; out to graphviz `dot' to render `docs/dependency-graph.svg' alongside the
;; intermediate `docs/dependency-graph.dot'.
;;
;; Master entrypoint `gptel-agent-runtime' is included as a separate top node
;; so the picture stays anchored at the load root.
;;
;; Invocation:
;;
;;     emacs -Q --batch -l scripts/refresh-dep-graph.el \
;;       -f gar-refresh-dep-graph-and-exit
;;
;; Requires graphviz on PATH (`brew install graphviz' on macOS).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar gar-dep-graph-root
  (or (and load-file-name (file-name-directory
                           (directory-file-name
                            (file-name-directory load-file-name))))
      default-directory)
  "Directory holding the gar-*.org/.el module files.")

(defconst gar-dep-graph-dot-file "docs/dependency-graph.dot")
(defconst gar-dep-graph-svg-file "docs/dependency-graph.svg")
(defconst gar-dep-graph-master-feature 'gptel-agent-runtime)

(defun gar-dep-graph--module-name (file)
  "Return the feature symbol (intern of base name) for FILE."
  (intern (file-name-base file)))

(defun gar-dep-graph--list-elisp-files ()
  "Return the master plus every gar-*.el module file in the package root."
  (let* ((root gar-dep-graph-root)
         (master (expand-file-name "gptel-agent-runtime.el" root))
         (gar-files
          (cl-remove-if-not
           (lambda (f) (string-match-p "^gar-" (file-name-nondirectory f)))
           (directory-files root t "\\`gar-[^.]*\\.el\\'"))))
    (if (file-exists-p master)
        (cons master gar-files)
      gar-files)))

(defun gar-dep-graph--scan-requires (elisp-file)
  "Return the list of hard-required `gar-*' feature symbols in ELISP-FILE.
Soft requires (`(require 'gar-foo nil t)') are excluded."
  (let (results)
    (with-temp-buffer
      (insert-file-contents elisp-file)
      (goto-char (point-min))
      (while (re-search-forward
              "(require[ \t\n]+'\\(gar-[^ \t\n)]+\\)" nil t)
        (let* ((sym (match-string 1))
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

(defun gar-dep-graph--build-edges ()
  "Return a list of (REQUIRER . REQUIREE) feature-symbol pairs.
Edges from the master come first, in master-require order, so DOT lays
out the bottom row of submodules left-to-right in actual load order."
  (let* ((files (gar-dep-graph--list-elisp-files))
         (master gar-dep-graph-master-feature)
         master-edges other-edges)
    (dolist (file files)
      (let ((src (gar-dep-graph--module-name file)))
        (dolist (req (gar-dep-graph--scan-requires file))
          (if (eq src master)
              (push (cons src req) master-edges)
            (push (cons src req) other-edges)))))
    (append (nreverse master-edges) (nreverse other-edges))))

(defun gar-dep-graph--master-load-order ()
  "Return the load order encoded by the master file's (require) sequence.
List of feature symbols, master first, then each gar-* in the order the
master requires them. Returns nil when the master file is missing."
  (let ((master (expand-file-name "gptel-agent-runtime.el"
                                  gar-dep-graph-root)))
    (when (file-exists-p master)
      (cons gar-dep-graph-master-feature
            (gar-dep-graph--scan-requires master)))))

(defun gar-dep-graph--collect-nodes (edges)
  "Return the unique list of node symbols mentioned in EDGES.
Nodes are ordered by the master's (require) sequence when known; remaining
nodes fall back to alphabetical order so the layout reads top-to-bottom
in actual load order."
  (let* ((all (cl-delete-duplicates
               (append (mapcar #'car edges) (mapcar #'cdr edges))
               :test #'eq))
         (order (gar-dep-graph--master-load-order))
         (in-order (cl-remove-if-not (lambda (n) (memq n all)) order))
         (others (sort (cl-set-difference all in-order)
                       (lambda (a b)
                         (string< (symbol-name a) (symbol-name b))))))
    (append in-order others)))

(defun gar-dep-graph--node-fill (n)
  "Return the DOT fillcolor (with surrounding quotes) for node symbol N."
  (let ((name (symbol-name n)))
    (cond
     ((eq n gar-dep-graph-master-feature) "\"#fde2c4\"")
     ((string= name "gar-core") "\"#cce8cc\"")
     ((member name '("gar-substrate" "gar-quarantine"
                     "gar-skeptic" "gar-policy"))
      "\"#dde8f5\"")
     ((member name '("gar-mission-control" "gar-canaries"
                     "gar-memory" "gar-tools" "gar-backend"
                     "gar-directives" "gar-context"
                     "gar-executor" "gar-agents"))
      "\"#f5f5f5\"")
     ((string= name "gar-loop") "\"#f9d6d6\"")
     (t "\"#ffffff\""))))

(defun gar-dep-graph--render-dot (edges)
  "Return the DOT source text for EDGES."
  (let ((nodes (gar-dep-graph--collect-nodes edges)))
    (with-temp-buffer
      (insert "// Auto-generated by scripts/refresh-dep-graph.el. Do not edit by hand.\n")
      (insert "// Edges point from a module to the modules it (require)s.\n")
      (insert "digraph gptel_agent_runtime {\n")
      (insert "  rankdir=TB;\n")
      (insert "  node [shape=box, style=\"rounded,filled\", fontname=\"Helvetica\", fontsize=11];\n")
      (insert "  edge [fontname=\"Helvetica\", fontsize=9, color=\"#666666\"];\n")
      (insert "  graph [splines=true, nodesep=0.3, ranksep=0.55];\n")
      (dolist (n nodes)
        (let* ((name (symbol-name n))
               (extras (if (eq n gar-dep-graph-master-feature)
                           ", ordering=\"out\""
                         "")))
          (insert (format "  \"%s\" [label=\"%s\", fillcolor=%s%s];\n"
                          name name (gar-dep-graph--node-fill n) extras))))
      (dolist (e edges)
        (insert (format "  \"%s\" -> \"%s\";\n"
                        (symbol-name (car e))
                        (symbol-name (cdr e)))))
      (insert "}\n")
      (buffer-string))))

(defun gar-dep-graph--write-and-render ()
  "Write DOT file and shell out to graphviz to produce the SVG.
Errors out when `dot' is not on PATH; the DOT file is still produced so a
manual `dot -Tsvg' invocation can recover."
  (let* ((root gar-dep-graph-root)
         (dot-path (expand-file-name gar-dep-graph-dot-file root))
         (svg-path (expand-file-name gar-dep-graph-svg-file root))
         (edges (gar-dep-graph--build-edges))
         (dot (gar-dep-graph--render-dot edges)))
    (unless (file-directory-p (file-name-directory dot-path))
      (make-directory (file-name-directory dot-path) t))
    (with-temp-file dot-path
      (insert dot))
    (message "gar-refresh-dep-graph: wrote %s (%d edges, %d nodes)"
             dot-path
             (length edges)
             (length (gar-dep-graph--collect-nodes edges)))
    (let* ((dot-exe (executable-find "dot")))
      (if (null dot-exe)
          (message "gar-refresh-dep-graph: WARNING `dot' not on PATH; SVG NOT regenerated. Run `brew install graphviz' and re-run this script.")
        (let ((exit (call-process dot-exe nil nil nil
                                  "-Tsvg" "-o" svg-path dot-path)))
          (if (eq exit 0)
              (message "gar-refresh-dep-graph: wrote %s" svg-path)
            (error "gar-refresh-dep-graph: dot exited with %s" exit)))))))

(defun gar-refresh-dep-graph ()
  "Regenerate the dependency graph DOT and SVG."
  (interactive)
  (gar-dep-graph--write-and-render))

(defun gar-refresh-dep-graph-and-exit ()
  "Batch entrypoint: regenerate the graph, then exit Emacs."
  (gar-refresh-dep-graph)
  (kill-emacs 0))

(provide 'refresh-dep-graph)

;;; refresh-dep-graph.el ends here
