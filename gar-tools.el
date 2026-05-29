;;; gar-tools.el --- tool registry + native gptel tools + tool-invention pipeline -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Extracted from the monolith
;; gptel-agent-runtime.org on 2026-05-27 as PR 5 of the module split.

;;; Commentary:

;; Owns three closely-related concerns:
;;
;;  - the `gptel-agent-runtime-tool' struct + `gptel-agent-runtime-tool-
;;    registry' alist + register/find/by-category helpers
;;  - the `gptel-agent-runtime-action-result' struct + result-ok/error/
;;    pending-reflection-p factories
;;  - every `gptel-make-tool' registration that exposes a runtime
;;    capability to the model (file/buffer/Org/code/export/web tools)
;;  - the tool-invention pipeline: propose -> static check -> subprocess
;;    sandbox -> manual approval (M-x gptel-agent-runtime-approve-proposed-tool)
;;
;; The raw-tool JSON shim that catches model-emitted JSON-as-text lives
;; in gar-executor; the allow-list defcustoms it reads stay in the
;; master so all the user-tunable tool config lives in one place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gptel)

(declare-function gptel-agent-runtime-emit-event "gptel-agent-runtime"
                  (type &rest args))
(declare-function gptel-agent-runtime--shorten "gptel-agent-runtime"
                  (text &optional max))
(declare-function gptel-agent-runtime--state-header "gptel-agent-runtime"
                  (&optional written-by))
(declare-function gptel-agent-runtime--read-versioned "gptel-agent-runtime"
                  (file))
(declare-function gptel-agent-runtime--timestamp "gptel-agent-runtime" ())
(declare-function gptel-agent-runtime-capability-summary "gptel-agent-runtime" ())

(defvar gptel-agent-runtime-tick-counter)

(cl-defstruct (gptel-agent-runtime-tool
               (:constructor gptel-agent-runtime-tool-create))
  "Metadata for a tool known to the future agent runtime."
  name
  category
  risk
  description
  package-ready-p
  local-only-p
  gptel-tool
  notes
  arg-schema)

(defvar gptel-agent-runtime-tool-registry nil
  "List of `gptel-agent-runtime-tool' entries registered for agent use.")

(defun gptel-agent-runtime-register-tool
    (name category risk description &rest plist)
  "Register tool metadata.
NAME is a string or symbol. CATEGORY and RISK are symbols. DESCRIPTION is a
human-readable summary. PLIST may include :package-ready-p, :local-only-p,
:gptel-tool, :notes, and :arg-schema (consumed by `gar-validator' as a
pre-flight gate inside the policy broker)."
  (let* ((tool-name (if (symbolp name) (symbol-name name) name))
         (entry (gptel-agent-runtime-tool-create
                 :name tool-name
                 :category category
                 :risk risk
                 :description description
                 :package-ready-p (plist-get plist :package-ready-p)
                 :local-only-p (plist-get plist :local-only-p)
                 :gptel-tool (plist-get plist :gptel-tool)
                 :notes (plist-get plist :notes)
                 :arg-schema (plist-get plist :arg-schema))))
    (setq gptel-agent-runtime-tool-registry
          (cons entry
                (cl-remove tool-name gptel-agent-runtime-tool-registry
                           :key #'gptel-agent-runtime-tool-name
                           :test #'equal)))
    entry))

(defun gptel-agent-runtime-find-tool (name)
  "Return registered tool metadata for NAME, or nil."
  (let ((tool-name (if (symbolp name) (symbol-name name) name)))
    (cl-find tool-name gptel-agent-runtime-tool-registry
             :key #'gptel-agent-runtime-tool-name
             :test #'equal)))

(defun gptel-agent-runtime-tools-by-category (category)
  "Return all registered tools in CATEGORY."
  (cl-remove-if-not
   (lambda (tool)
     (eq (gptel-agent-runtime-tool-category tool) category))
   gptel-agent-runtime-tool-registry))

(cl-defstruct (gptel-agent-runtime-action-result
               (:constructor gptel-agent-runtime-action-result-create))
  "Normalized result of one agent action or tool call."
  status
  tool
  output
  error
  warnings
  changed-files
  changed-buffers
  reflection-needed-p
  metadata)

(cl-defun gptel-agent-runtime-result-ok
    (&key tool output warnings changed-files changed-buffers metadata)
  "Create a successful action result."
  (gptel-agent-runtime-action-result-create
   :status 'ok
   :tool tool
   :output output
   :warnings warnings
   :changed-files changed-files
   :changed-buffers changed-buffers
   :reflection-needed-p nil
   :metadata metadata))

(cl-defun gptel-agent-runtime-result-error
    (&key tool error output warnings metadata)
  "Create a failed action result."
  (gptel-agent-runtime-action-result-create
   :status 'error
   :tool tool
   :output output
   :error error
   :warnings warnings
   :changed-files nil
   :changed-buffers nil
   :reflection-needed-p t
   :metadata metadata))

(defun gptel-agent-runtime-result-pending-reflection-p (result)
  "Return non-nil when RESULT should trigger a reflection step."
  (or (eq (gptel-agent-runtime-action-result-status result) 'error)
      (gptel-agent-runtime-action-result-reflection-needed-p result)))

;; ===== Phase 5: tool-invention pipeline =====

(defcustom gptel-agent-runtime-tool-invention-enabled t
  "When non-nil, the runtime accepts tool-invention proposals.
Proposed tools are saved to
`~/.emacs.d/gptel-agent-runtime/proposed-tools/' and never auto-registered.
They become live only after passing static analysis, subprocess validation,
and explicit user approval via
`M-x gptel-agent-runtime-review-proposed-tools'."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-tool-invention-denied-forms
  '(shell-command
    shell-command-to-string
    call-process call-process-region call-process-shell-command
    process-file
    start-process start-process-shell-command
    make-process
    make-network-process
    url-retrieve url-retrieve-synchronously
    delete-file delete-directory
    rename-file copy-file copy-directory
    write-file write-region append-to-file
    eval eval-region eval-buffer eval-expression
    load load-file load-library
    require autoload
    intern
    setq set setq-default fset fmakunbound makunbound
    advice-add advice-remove
    add-hook remove-hook
    kill-emacs save-buffers-kill-emacs)
  "Symbols that may NOT appear anywhere inside a proposed-tool body.
The static analyzer walks the proposed s-expression and rejects the
proposal if any of these symbols appears in functional position. The
denied list is conservative on purpose; users can edit this list to relax
it for trusted environments, but the default targets shell/file/eval
escape hatches and primitive low-level mutation."
  :type '(repeat symbol)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-tool-invention-allowed-prefixes
  '("gptel-agent-runtime-" "gptel-")
  "Function-symbol prefixes whose calls are always allowed inside proposals.
Used as a positive allowlist: even when a function name overlaps a denied
form, callers prefixed by one of these strings are still permitted. Empty
list means no prefix-based allowlist."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-tool-invention-subprocess-timeout 30
  "Maximum seconds the subprocess validator may run."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime--proposed-tools-directory ()
  "Return (and create) the proposed-tools directory."
  (let ((dir (expand-file-name
              "gptel-agent-runtime/proposed-tools/"
              user-emacs-directory)))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--rejected-tools-directory ()
  "Return (and create) the rejected-tools directory."
  (let ((dir (expand-file-name "rejected/"
                               (gptel-agent-runtime--proposed-tools-directory))))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun gptel-agent-runtime--symbol-allowed-prefix-p (sym)
  "Return non-nil when SYM's name starts with an allowed prefix."
  (let ((name (and (symbolp sym) (symbol-name sym))))
    (and name
         (cl-some (lambda (p) (string-prefix-p p name))
                  gptel-agent-runtime-tool-invention-allowed-prefixes))))

(defun gptel-agent-runtime--safe-form-violations (form)
  "Walk FORM and return a list of (SYMBOL . PATH) violations.
PATH is a short description like \"head\" or `apply' for diagnostics.
Returns nil when no denied symbol appears in functional position."
  (let ((violations nil))
    (cl-labels
        ((walk (node)
           (cond
            ((not (consp node)) nil)
            ((symbolp (car node))
             (let ((head (car node)))
               (when (and (memq head gptel-agent-runtime-tool-invention-denied-forms)
                          (not (gptel-agent-runtime--symbol-allowed-prefix-p head)))
                 (push (cons head 'head) violations))
               ;; Catch (funcall 'symbol ...) and (apply 'symbol ...)
               (when (memq head '(funcall apply))
                 (let ((target (cadr node)))
                   (when (and (consp target)
                              (eq (car target) 'quote)
                              (symbolp (cadr target))
                              (memq (cadr target)
                                    gptel-agent-runtime-tool-invention-denied-forms)
                              (not (gptel-agent-runtime--symbol-allowed-prefix-p
                                    (cadr target))))
                     (push (cons (cadr target) head) violations))))
               (mapc #'walk (cdr node))))
            (t (mapc #'walk node)))))
      (walk form))
    (nreverse violations)))

(defun gptel-agent-runtime--read-all-forms (file)
  "Read all top-level Lisp forms from FILE and return them as a list."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms form)
      (while (setq form (condition-case nil
                            (read (current-buffer))
                          (end-of-file nil)))
        (push form forms))
      (nreverse forms))))

(cl-defun gptel-agent-runtime-propose-tool
    (&key name description args-schema body-elisp required-caps risk
          rationale tests author)
  "Save a tool proposal under proposed-tools/ and emit a submission event.
NAME (string) is the proposed tool name. DESCRIPTION is user-facing text.
ARGS-SCHEMA is an arg description (plist or JSON-shaped sexp).
BODY-ELISP is a single Lisp form (the proposed defun body). REQUIRED-CAPS
is a list of capability symbols. RISK is one of safe/read/write/shell/
destructive. RATIONALE is the inventor's reasoning. TESTS is an optional
list of (INPUT EXPECTED) pairs for the subprocess validator. AUTHOR is an
optional name. Returns the absolute file path."
  (unless gptel-agent-runtime-tool-invention-enabled
    (user-error "Tool invention is disabled."))
  (unless (and (stringp name) (not (string-empty-p name)))
    (user-error "Tool proposal needs a non-empty :name string"))
  (unless body-elisp
    (user-error "Tool proposal needs :body-elisp"))
  (let* ((dir (gptel-agent-runtime--proposed-tools-directory))
         (file (expand-file-name
                (format "%s-%s.el"
                        name
                        gptel-agent-runtime-tick-counter)
                dir))
         (payload (list :name name
                        :description description
                        :args-schema args-schema
                        :body-elisp body-elisp
                        :required-caps required-caps
                        :risk (or risk 'write)
                        :rationale rationale
                        :tests tests
                        :author author
                        :submitted-tick gptel-agent-runtime-tick-counter
                        :submitted-at (gptel-agent-runtime--timestamp))))
    (with-temp-file file
      (let ((create-lockfiles nil))
        (prin1 (gptel-agent-runtime--state-header "tool-invention")
               (current-buffer))
        (insert "\n")
        (prin1 payload (current-buffer))
        (insert "\n")))
    (gptel-agent-runtime-emit-event
     'tool-proposal-submitted
     :source "tool-invention"
     :payload (list :name name :file file)
     :taint 'trusted)
    file))

(defun gptel-agent-runtime--read-proposal (file)
  "Return the proposal plist stored in FILE, or nil when unreadable."
  (let* ((parsed (gptel-agent-runtime--read-versioned file))
         (rest (cdr parsed)))
    (when rest
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char rest)
        (condition-case nil (read (current-buffer)) (error nil))))))

(defun gptel-agent-runtime--locate-emacs-binary ()
  "Return an absolute path to the running Emacs binary, or nil."
  (let ((candidate (expand-file-name invocation-name invocation-directory)))
    (cond
     ((and (stringp candidate) (file-executable-p candidate)) candidate)
     ((executable-find "emacs"))
     (t nil))))

(defun gptel-agent-runtime-validate-proposed-tool (file)
  "Validate the proposal at FILE through static + subprocess checks.
Returns a plist with :file, :static-violations, :subprocess-exit-code,
:subprocess-stdout, :subprocess-stderr, :passed-p, :passed-static-p."
  (let* ((proposal (gptel-agent-runtime--read-proposal file))
         (body (plist-get proposal :body-elisp))
         (violations (and body
                          (gptel-agent-runtime--safe-form-violations body)))
         (passed-static (null violations))
         (sub-stdout "") (sub-stderr "") (sub-exit nil))
    (when (and passed-static body)
      (let* ((emacs-bin (gptel-agent-runtime--locate-emacs-binary))
             (body-file (make-temp-file "gar-body-" nil ".el"))
             (script-file (make-temp-file "gar-validator-" nil ".el")))
        (unwind-protect
            (when emacs-bin
              ;; Dump the proposed body alone to a candidate file we can
              ;; byte-compile in a clean subprocess.
              (with-temp-file body-file
                (let ((print-level nil) (print-length nil)
                      (create-lockfiles nil))
                  (insert ";;; gptel-agent-runtime proposed tool body -*- lexical-binding: t; -*-\n")
                  (prin1 body (current-buffer))
                  (insert "\n(provide 'gar-proposed-body)\n")))
              ;; Validator script: byte-compile inside `with-timeout', print
              ;; a structured outcome line, never load the body code itself.
              (with-temp-file script-file
                (let ((print-level nil) (print-length nil)
                      (create-lockfiles nil)
                      (timeout
                       (max 1 gptel-agent-runtime-tool-invention-subprocess-timeout)))
                  (insert ";;; gptel-agent-runtime tool-invention validator -*- lexical-binding: t; -*-\n")
                  (insert "(setq byte-compile-error-on-warn nil)\n")
                  (insert
                   (format "(with-timeout (%d (princ \"timeout\\n\") (kill-emacs 124))\n"
                           timeout))
                  (insert
                   (format "  (let ((res (byte-compile-file %S)))\n"
                           body-file))
                  (insert "    (princ (format \"compile=%s\\n\" res))\n")
                  (insert "    (kill-emacs (if res 0 1))))\n")))
              ;; Run subprocess. We do not use the shell so there are no
              ;; shell-expansion or `timeout(1)' portability issues.
              (with-temp-buffer
                (let* ((default-directory temporary-file-directory)
                       (proc-exit (call-process emacs-bin nil
                                                (current-buffer) nil
                                                "-Q" "--batch"
                                                "-l" script-file)))
                  (setq sub-exit proc-exit
                        sub-stdout (buffer-string)
                        sub-stderr ""))))
          (ignore-errors (delete-file body-file))
          (ignore-errors (delete-file (concat body-file "c")))
          (ignore-errors (delete-file script-file)))))
    (let ((passed (and passed-static (numberp sub-exit) (zerop sub-exit))))
      (list :file file
            :static-violations violations
            :passed-static-p passed-static
            :subprocess-exit-code sub-exit
            :subprocess-stdout sub-stdout
            :subprocess-stderr sub-stderr
            :passed-p passed))))

(defun gptel-agent-runtime-list-proposed-tools ()
  "Return the list of proposed-tool files awaiting review."
  (let ((dir (gptel-agent-runtime--proposed-tools-directory)))
    (when (file-directory-p dir)
      (cl-remove-if (lambda (f) (file-directory-p f))
                    (directory-files dir t "\\.el\\'")))))

;;;###autoload
(defun gptel-agent-runtime-approve-proposed-tool (file)
  "Approve and register the proposed tool from FILE.
Static + subprocess validation must pass. The new tool is registered via
`gptel-agent-runtime-register-tool' with its declared :required-caps and
:risk. The mapping is also added to `gptel-agent-runtime-tool-capabilities'
so the zero-trust capability gate enforces it from the next call onward.
Emits `tool-proposal-approved'. The proposal file is left in place for
provenance and is renamed with a `.approved' suffix."
  (interactive
   (list (read-file-name "Proposal file: "
                         (gptel-agent-runtime--proposed-tools-directory))))
  (let* ((proposal (gptel-agent-runtime--read-proposal file))
         (result (gptel-agent-runtime-validate-proposed-tool file)))
    (unless (plist-get result :passed-p)
      (user-error
       "Validation did not pass; static-violations=%s exit=%s stderr=%s"
       (plist-get result :static-violations)
       (plist-get result :subprocess-exit-code)
       (gptel-agent-runtime--shorten
        (plist-get result :subprocess-stderr) 200)))
    (let* ((name (plist-get proposal :name))
           (caps (plist-get proposal :required-caps))
           (risk (or (plist-get proposal :risk) 'write)))
      (when name
        ;; Register in the package-shaped registry.
        (gptel-agent-runtime-register-tool
         name 'invented risk
         (or (plist-get proposal :description) "Invented tool")
         :notes (plist-get proposal :rationale))
        ;; Add to the zero-trust capability manifest.
        (let ((entry (assoc name gptel-agent-runtime-tool-capabilities)))
          (if entry
              (setcdr entry (or caps '()))
            (push (cons name (or caps '()))
                  gptel-agent-runtime-tool-capabilities))))
      (let ((approved-file (concat file ".approved")))
        (ignore-errors (rename-file file approved-file t)))
      (gptel-agent-runtime-emit-event
       'tool-proposal-approved
       :source "tool-invention"
       :payload (list :name name :caps caps :risk risk)
       :taint 'trusted)
      (when (called-interactively-p 'interactive)
        (message "gptel-agent-runtime: approved %s" name))
      name)))

;;;###autoload
(defun gptel-agent-runtime-reject-proposed-tool (file &optional reason)
  "Move FILE to the rejected/ subdirectory. REASON is recorded in a sidecar."
  (interactive
   (list (read-file-name "Proposal file: "
                         (gptel-agent-runtime--proposed-tools-directory))
         (read-string "Reason: ")))
  (let* ((base (file-name-nondirectory file))
         (rejected-file (expand-file-name
                         base
                         (gptel-agent-runtime--rejected-tools-directory))))
    (rename-file file rejected-file t)
    (when (and reason (not (string-empty-p reason)))
      (with-temp-file (concat rejected-file ".reason")
        (insert reason "\n")))
    (when (called-interactively-p 'interactive)
      (message "gptel-agent-runtime: rejected %s" base))
    rejected-file))

;;;###autoload
(defun gptel-agent-runtime-review-proposed-tools ()
  "Open a buffer summarizing proposed tools and their validation status."
  (interactive)
  (let* ((files (gptel-agent-runtime-list-proposed-tools)))
    (with-current-buffer (get-buffer-create "*gptel-agent-proposed-tools*")
      (erase-buffer)
      (insert (format "gptel-agent-runtime proposed tools\nDirectory: %s\nCount: %d\n\n"
                      (gptel-agent-runtime--proposed-tools-directory)
                      (length files)))
      (if (null files)
          (insert "  (no proposed tools pending)\n")
        (dolist (file files)
          (let* ((proposal (gptel-agent-runtime--read-proposal file))
                 (result (gptel-agent-runtime-validate-proposed-tool file)))
            (insert (format "  %s\n"
                            (file-name-nondirectory file)))
            (insert (format "    name: %s\n    caps: %s\n    risk: %s\n    static-violations: %s\n    subprocess-exit: %s\n    passed: %s\n    rationale: %s\n\n"
                            (plist-get proposal :name)
                            (or (plist-get proposal :required-caps) '())
                            (or (plist-get proposal :risk) 'write)
                            (or (plist-get result :static-violations) "(none)")
                            (plist-get result :subprocess-exit-code)
                            (plist-get result :passed-p)
                            (gptel-agent-runtime--shorten
                             (or (plist-get proposal :rationale) "") 200))))))
      (insert "\nUse M-x gptel-agent-runtime-approve-proposed-tool / -reject-proposed-tool\n")
      (goto-char (point-min))
      (special-mode))
    (display-buffer "*gptel-agent-proposed-tools*")))

(defun gptel-agent-runtime--path-protected-p (path)
  "Return non-nil when PATH is protected from agent writes.
Delegates to the host-defined `my/gptel-protected-p' when bound (some
user configs define one to fence off the literate-config files);
returns nil otherwise so the package works standalone."
  (and (fboundp 'my/gptel-protected-p)
       (funcall (symbol-function 'my/gptel-protected-p) path)))

(with-eval-after-load 'gptel
  ;; describe_capabilities — deterministic summary of current runtime tools
  (gptel-make-tool
   :name "describe_capabilities"
   :description "Return the actual registered Emacs agent tools, agent roles, organization units, learned playbooks, safety policy, and guidance for describing capabilities."
   :function (lambda ()
               (gptel-agent-runtime-capability-summary)))

  ;; get_todos — return the current TODO list as text
  (gptel-make-tool
   :name "get_todos"
   :description "Return all open TODO entries from the org agenda."
   :function (lambda ()
               (mapconcat
                (lambda (e)
                  (format "[%s] %s%s"
                          (plist-get e :state)
                          (plist-get e :heading)
                          (let ((dl (plist-get e :deadline)))
                            (if (and dl (not (string-empty-p dl)))
                                (format " (due %s)" dl) ""))))
                (gptel-agent-runtime-collect-org-todos 200) "\n")))

  ;; read_org_file — get raw text of an org file
  (gptel-make-tool
   :name "read_org_file"
   :description "Read the contents of an org file. Path relative to ~ is accepted."
   :args '((:name "path" :type string :description "Org file path, e.g. ~/org/todo.org — use your actual data dir"))
   :function (lambda (path)
               (let ((p (expand-file-name path)))
                 (if (file-exists-p p)
                     (with-temp-buffer
                       (insert-file-contents p)
                       (buffer-string))
                   (format "File not found: %s" p)))))

  ;; write_org_file — overwrite an org file
  (gptel-make-tool
   :name "write_org_file"
   :description "Overwrite an org file with new content. Creates the file if absent. Cannot write to protected config files."
   :args '((:name "path"    :type string :description "File path")
           (:name "content" :type string :description "Full new file content"))
   :function (lambda (path content)
               (let ((p (file-truename (expand-file-name path))))
                 (if (gptel-agent-runtime--path-protected-p p)
                     (format "Error: %s is a protected config file — use read_file to inspect it, never write." p)
                   (make-directory (file-name-directory p) t)
                   (with-temp-file p (insert content))
                   (format "Written: %s" p)))))

  ;; add_todo — append a new TODO heading to a file
  (gptel-make-tool
   :name "add_todo"
   :description "Append a new TODO entry to an org file."
   :args '((:name "file"    :type string :description "Target org file path")
           (:name "heading" :type string :description "Heading text (without TODO keyword)")
           (:name "state"   :type string :description "TODO state, e.g. TODO, NEXT")
           (:name "body"    :type string :description "Optional body text"))
   :function (lambda (file heading state body)
               (let ((p (expand-file-name file)))
                 (with-current-buffer (find-file-noselect p)
                   (goto-char (point-max))
                   (insert (format "\n* %s %s\n%s" state heading (or body "")))
                   (save-buffer))
                 (format "Added %s: %s to %s" state heading p))))

  ;; change_todo_state — change state of a heading by exact title match
  (gptel-make-tool
   :name "change_todo_state"
   :description "Change the TODO state of a heading that matches the given title."
   :args '((:name "file"    :type string :description "Org file path")
           (:name "heading" :type string :description "Exact heading text (case-insensitive)")
           (:name "state"   :type string :description "New state, e.g. DONE, IN-PROGRESS"))
   :function (lambda (file heading state)
               (let ((p (expand-file-name file))
                     found)
                 (with-current-buffer (find-file-noselect p)
                   (goto-char (point-min))
                   (while (re-search-forward
                           (concat "^\\*+ \\(?:[A-Z]+ \\)?" (regexp-quote heading))
                           nil t)
                     (org-todo state)
                     (setq found t))
                   (when found (save-buffer)))
                 (if found
                     (format "State set to %s for: %s" state heading)
                   (format "Heading not found: %s" heading)))))

  ;; set_deadline — set or update deadline on a heading
  (gptel-make-tool
   :name "set_deadline"
   :description "Set a DEADLINE on a heading. Use ISO date format YYYY-MM-DD."
   :args '((:name "file"    :type string :description "Org file path")
           (:name "heading" :type string :description "Exact heading text")
           (:name "date"    :type string :description "Date string YYYY-MM-DD"))
   :function (lambda (file heading date)
               (let ((p (expand-file-name file))
                     found)
                 (with-current-buffer (find-file-noselect p)
                   (goto-char (point-min))
                   (when (re-search-forward
                          (concat "^\\*+ \\(?:[A-Z]+ \\)?" (regexp-quote heading))
                          nil t)
                     (org-deadline nil date)
                     (setq found t)
                     (save-buffer)))
                 (if found
                     (format "Deadline %s set on: %s" date heading)
                   (format "Heading not found: %s" heading)))))

  ;; add_tag — add a tag to a heading
  (gptel-make-tool
   :name "add_tag"
   :description "Add a tag to a matching org heading."
   :args '((:name "file"    :type string :description "Org file path")
           (:name "heading" :type string :description "Exact heading text")
           (:name "tag"     :type string :description "Tag to add (no colons)"))
   :function (lambda (file heading tag)
               (let ((p (expand-file-name file))
                     found)
                 (with-current-buffer (find-file-noselect p)
                   (goto-char (point-min))
                   (when (re-search-forward
                          (concat "^\\*+ \\(?:[A-Z]+ \\)?" (regexp-quote heading))
                          nil t)
                     (org-set-tags (cons tag (org-get-tags nil t)))
                     (setq found t)
                     (save-buffer)))
                 (if found
                     (format "Tag :%s: added to: %s" tag heading)
                   (format "Heading not found: %s" heading)))))

  ;; get_org_structure — outline of an org file (headings only)
  (gptel-make-tool
   :name "get_org_structure"
   :description "Return the heading outline of an org file without body text."
   :args '((:name "path" :type string :description "Org file path"))
   :function (lambda (path)
               (let ((p (expand-file-name path)))
                 (if (not (file-exists-p p))
                     (format "File not found: %s" p)
                   (with-temp-buffer
                     (insert-file-contents p)
                     (org-mode)
                     (let (lines)
                       (org-map-entries
                        (lambda ()
                          (push (concat (make-string (org-outline-level) ?*) " "
                                        (org-get-heading t t t t))
                                lines)))
                       (mapconcat #'identity (nreverse lines) "\n"))))))))

(with-eval-after-load 'gptel
  ;; execute_code — run a snippet in a temp org babel block
  (gptel-make-tool
   :name "execute_code"
   :description "Execute a code snippet and return the output. Supported languages: python, bash, sh, R, emacs-lisp."
   :args '((:name "language" :type string :description "Language: python, bash, sh, R, emacs-lisp")
           (:name "code"     :type string :description "Source code to execute"))
   :function (lambda (language code)
               (let* ((lang (downcase language))
                      (tmp  (make-temp-file "gptel-exec-" nil ".org"))
                      result)
                 (with-temp-file tmp
                   (insert (format "#+begin_src %s\n%s\n#+end_src\n" lang code)))
                 (with-temp-buffer
                   (insert-file-contents tmp)
                   (org-mode)
                   (goto-char (point-min))
                   (when (search-forward "#+begin_src" nil t)
                     (beginning-of-line)
                     (condition-case err
                         (let* ((info (org-babel-get-src-block-info))
                                (res  (org-babel-execute-src-block nil info)))
                           (setq result (if res (format "%s" res) "(no output)")))
                       (error (setq result (format "Error: %s" err))))))
                 (delete-file tmp)
                 (or result "(no output)"))))

  ;; run_elisp — evaluate elisp and return the result
  (gptel-make-tool
   :name "run_elisp"
   :description "Evaluate Emacs Lisp and return the printed result. Use for Emacs introspection and automation. Cannot write to protected config files."
   :args '((:name "code" :type string :description "Elisp expression(s) to evaluate"))
   :function (lambda (code)
               (condition-case err
                   (let ((orig-write-file (symbol-function 'write-file))
                         (orig-set-visited-file-name
                          (symbol-function 'set-visited-file-name)))
                     (cl-letf (((symbol-function 'write-file)
                                (lambda (file &rest args)
                                  (if (gptel-agent-runtime--path-protected-p (expand-file-name file))
                                      (error "write-file blocked by run_elisp: %s is protected" file)
                                    (apply orig-write-file file args))))
                               ((symbol-function 'set-visited-file-name)
                                (lambda (file &rest args)
                                  (if (and file (not (string-empty-p file))
                                           (gptel-agent-runtime--path-protected-p (expand-file-name file)))
                                      (error "set-visited-file-name blocked by run_elisp: %s is protected" file)
                                    (apply orig-set-visited-file-name file args)))))
                       (let ((result (eval (car (read-from-string
                                                 (concat "(progn " code ")"))))))
                         (format "%S" result))))
                 (error (format "Error: %s" err))))))

(with-eval-after-load 'gptel
  ;; read_file — read any text file
  (gptel-make-tool
   :name "read_file"
   :description "Read the contents of any text file on disk."
   :args '((:name "path" :type string :description "Absolute or ~-relative file path"))
   :function (lambda (path)
               (let ((p (expand-file-name path)))
                 (if (file-exists-p p)
                     (with-temp-buffer
                       (insert-file-contents p)
                       (buffer-string))
                   (format "File not found: %s" p)))))

  ;; write_file — write content to any file
  (gptel-make-tool
   :name "write_file"
   :description "Write content to a file, creating parent directories if needed. Cannot write to protected config files."
   :args '((:name "path"    :type string :description "File path")
           (:name "content" :type string :description "Content to write"))
   :function (lambda (path content)
               (let ((p (file-truename (expand-file-name path))))
                 (if (gptel-agent-runtime--path-protected-p p)
                     (format "Error: %s is a protected config file — use read_file to inspect it, never write." p)
                   (make-directory (file-name-directory p) t)
                   (with-temp-file p (insert content))
                   (format "Written: %s" p)))))

  ;; list_directory — list files in a directory
  (gptel-make-tool
   :name "list_directory"
   :description "List files and directories at a given path."
   :args '((:name "path"      :type string  :description "Directory path")
           (:name "recursive" :type boolean :description "If true, list recursively"))
   :function (lambda (path recursive)
               (let ((p (expand-file-name path)))
                 (if (not (file-directory-p p))
                     (format "Not a directory: %s" p)
                   (if recursive
                       (mapconcat #'identity
                                  (directory-files-recursively p "." nil nil t)
                                  "\n")
                     (mapconcat #'identity
                                (directory-files p t nil t)
                                "\n"))))))

  ;; search_files — grep-style search
  (gptel-make-tool
   :name "search_files"
   :description "Search for a regex pattern across files under a directory."
   :args '((:name "directory" :type string :description "Root directory for search")
           (:name "pattern"   :type string :description "Regex pattern")
           (:name "glob"      :type string :description "File glob, e.g. *.org (optional)"))
   :function (lambda (directory pattern glob)
               (let* ((dir  (expand-file-name directory))
                      (args (if (and glob (not (string-empty-p glob)))
                                (list "grep" "-r" "--include" glob "-n" pattern dir)
                              (list "grep" "-r" "-n" pattern dir))))
                 (with-temp-buffer
                   (apply #'call-process (car args) nil t nil (cdr args))
                   (if (string-empty-p (buffer-string))
                       "No matches found."
                     (buffer-string)))))))

(with-eval-after-load 'gptel
  ;; list_buffers — list all open buffers
  (gptel-make-tool
   :name "list_buffers"
   :description "Return the names of all currently open Emacs buffers."
   :function (lambda ()
               (mapconcat #'buffer-name (buffer-list) "\n")))

  ;; get_buffer_content — get text of a named buffer
  (gptel-make-tool
   :name "get_buffer_content"
   :description "Return the full text content of an open Emacs buffer."
   :args '((:name "name" :type string :description "Buffer name as shown by list_buffers"))
   :function (lambda (name)
               (let ((buf (get-buffer name)))
                 (if buf
                     (with-current-buffer buf (buffer-string))
                   (format "Buffer not found: %s" name))))))

(with-eval-after-load 'gptel
  ;; org_export — export an org file to a target format
  (gptel-make-tool
   :name "org_export"
   :description "Export an org file to html, pdf, md, reveal (slides), or beamer. Returns the output file path."
   :args '((:name "path"   :type string :description "Org file to export")
           (:name "format" :type string :description "Output format: html, pdf, md, reveal, beamer"))
   :function (lambda (path format)
               (let ((p (expand-file-name path)))
                 (if (not (file-exists-p p))
                     (format "File not found: %s" p)
                   (with-current-buffer (find-file-noselect p)
                     (condition-case err
                         (pcase (downcase format)
                           ("html"
                            (org-html-export-to-html)
                            (format "Exported to: %s.html" (file-name-sans-extension p)))
                           ("pdf"
                            (org-latex-export-to-pdf)
                            (format "Exported to: %s.pdf" (file-name-sans-extension p)))
                           ("md"
                            (org-md-export-to-markdown)
                            (format "Exported to: %s.md" (file-name-sans-extension p)))
                           ("reveal"
                            (if (fboundp 'org-reveal-export-to-html)
                                (progn (org-reveal-export-to-html)
                                       (format "Exported to: %s.html" (file-name-sans-extension p)))
                              "org-reveal not installed."))
                           ("beamer"
                            (org-beamer-export-to-pdf)
                            (format "Exported to: %s.pdf" (file-name-sans-extension p)))
                           (_ (format "Unknown format: %s" format)))
                       (error (format "Export error: %s" err)))))))))

(with-eval-after-load 'gptel
  ;; web_search — search the public web and return org links
  (gptel-make-tool
   :name "web_search"
   :description "Search the internet. Use this for current/latest information, laws, regulations, prices, dates, versions, and anything the user asks to check online."
   :args '((:name "query" :type string :description "Search query")
           (:name "limit" :type integer :description "Maximum number of results, default 5"))
   :function (lambda (query limit)
               (condition-case err
                   (let ((results (gptel-agent-runtime-web-search-ddg query (or limit 5))))
                     (if results
                         (mapconcat
                          (lambda (r)
                            (format "- [[%s][%s]]" (cdr r) (car r)))
                          results "\n")
                       "No search results found."))
                 (error (format "Error: %s" err)))))

  ;; web_fetch_text — fetch a page as readable text
  (gptel-make-tool
   :name "web_fetch_text"
   :description "Fetch a URL and return readable text extracted from the page. Use after web_search to inspect official/primary sources before answering."
   :args '((:name "url" :type string :description "URL to fetch")
           (:name "max_chars" :type integer :description "Maximum characters to return, default 6000"))
   :function (lambda (url max-chars)
               (condition-case err
                   (gptel-agent-runtime-web-text url (or max-chars 6000))
                 (error (format "Error: %s" err)))))

  ;; web_extract_images — list image URLs from a page
  (gptel-make-tool
   :name "web_extract_images"
   :description "Extract image URLs from a web page."
   :args '((:name "url" :type string :description "URL to inspect")
           (:name "limit" :type integer :description "Maximum number of images, default 10"))
   :function (lambda (url limit)
               (condition-case err
                   (let ((images (gptel-agent-runtime-web-extract-images url (or limit 10))))
                     (if images
                         (mapconcat #'identity images "\n")
                       "No images found."))
                 (error (format "Error: %s" err)))))

  ;; web_fetch_image — download an image locally
  (gptel-make-tool
   :name "web_fetch_image"
   :description "Download an image URL and return the local file path."
   :args '((:name "url" :type string :description "Image URL")
           (:name "directory" :type string :description "Optional target directory"))
   :function (lambda (url directory)
               (condition-case err
                   (gptel-agent-runtime-web-fetch-image
                    url
                    (when (and directory (not (string-empty-p directory)))
                      (expand-file-name directory)))
                 (error (format "Error: %s" err))))))

(with-eval-after-load 'gptel
  ;; Set globally -- all tools are registered by this point since this section
  ;; is the last with-eval-after-load 'gptel block in the module. Guarded with
  ;; `fboundp' because `gptel-agent-runtime-tools-all' is defined later in the master's
  ;; Model Switching section, which loads AFTER gar-tools is required. A
  ;; matching call in the master finishes the wiring once Model Switching
  ;; has installed the helper.
  (setq gptel-use-tools t)
  (when (fboundp 'gptel-agent-runtime-tools-all)
    (setq gptel-tools (gptel-agent-runtime-tools-all))))

(defvar gptel-agent-runtime--current-session nil
  "The active agent session object.")

(defvar gptel-agent-runtime--origin-buffer nil
  "Buffer where the current agent session should render user-visible output.")

(gptel-agent-runtime-register-tool
 "run_elisp" 'invoke 'destructive
 "Evaluate Emacs Lisp; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:code (:type string :min-length 1))
   :required (:code)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "execute_code" 'invoke 'destructive
 "Execute a code snippet; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:language (:type string
                           :enum ("python" "bash" "sh" "R" "emacs-lisp"))
                :code (:type string :min-length 1))
   :required (:language :code)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "write_file" 'mutate 'write
 "Write content to a file; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:path (:type string :min-length 1)
                :content (:type string))
   :required (:path :content)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "write_org_file" 'mutate 'write
 "Overwrite an org file; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:path (:type string :min-length 1
                       :pattern "\\.org\\'")
                :content (:type string))
   :required (:path :content)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "add_todo" 'mutate 'write
 "Append a TODO heading to an org file; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:file (:type string :min-length 1)
                :heading (:type string :min-length 1)
                :state (:type string :min-length 1)
                :body (:type string))
   :required (:file :heading :state)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "change_todo_state" 'mutate 'write
 "Change the TODO state of an org heading; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:file (:type string :min-length 1)
                :heading (:type string :min-length 1)
                :state (:type string :min-length 1))
   :required (:file :heading :state)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "set_deadline" 'mutate 'write
 "Set DEADLINE on an org heading; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:file (:type string :min-length 1)
                :heading (:type string :min-length 1)
                :date (:type string
                       :pattern "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"))
   :required (:file :heading :date)
   :additional-properties nil))

(gptel-agent-runtime-register-tool
 "add_tag" 'mutate 'write
 "Add a tag to an org heading; pre-flighted via arg-schema."
 :arg-schema
 '(:type object
   :properties (:file (:type string :min-length 1)
                :heading (:type string :min-length 1)
                :tag (:type string :min-length 1
                      :pattern "\\`[A-Za-z0-9_@]+\\'"))
   :required (:file :heading :tag)
   :additional-properties nil))

(provide 'gar-tools)

;;; gar-tools.el ends here
