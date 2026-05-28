;;; gar-backend.el --- Ollama runtime utilities + backend registry forward decls -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Extracted from the monolith
;; gptel-agent-runtime.org on 2026-05-27 as PR 3 of the module split.

;;; Commentary:

;; Provider-neutral runtime layer. Forward-declares the `my/gptel-backends'
;; alist (populated by the consuming setup file with API keys/endpoints).
;; Provides the Ollama runtime helpers (server probe, auto-start, active-
;; model detection, default-local-model selection) and the model-id
;; normalization helpers that the model router and selection UI use.
;;
;; Backend CONSTRUCTORS (`gptel-make-anthropic', `gptel-make-openai',
;; `gptel-make-ollama' ...) intentionally do NOT live here -- they belong
;; in the user's host configuration where API keys and machine
;; preferences are kept. Keeping those out of the package lets it stay
;; reusable across hosts and safe to distribute.

;;; Code:

(require 'cl-lib)
(require 'gptel)

;; Cross-module callees provided by other modules; declared here so the
;; byte-compiler does not warn during isolated compilation.
(declare-function my/gptel-sync-directive-for-current-runtime "gar-directives" ())
(declare-function my/gptel-sync-tools "gptel-agent-runtime" ())

;; Defcustoms read by this module are defined in the master; declare them
;; as `defvar' here so the byte-compiler accepts the references.
(defvar gptel-agent-runtime-ollama-host)
(defvar gptel-agent-runtime-ollama-command)
(defvar gptel-agent-runtime-ollama-models-directory)
(defvar gptel-agent-runtime-auto-start-ollama)
(defvar gptel-agent-runtime-prefer-active-ollama-model)
(defvar gptel-agent-runtime-default-local-model)
(defvar gptel-agent-runtime-default-local-model-label)

(defvar my/gptel-backends nil
  "Alist of (DISPLAY-NAME . (BACKEND . MODEL)) for all backends.
Populated by the consuming setup file; the runtime package only forward-
declares it.")

(defvar my/gptel-ollama-backend nil
  "The registered Ollama backend, when the setup file has installed one.
Forward-declared by the package; populated by the setup file.")

(defun gptel-agent-runtime--ollama-url (&optional path)
  "Return the local Ollama URL for PATH."
  (format "http://%s%s"
          gptel-agent-runtime-ollama-host
          (or path "")))

(defun gptel-agent-runtime-ollama-running-p ()
  "Return non-nil when the configured Ollama server responds."
  (condition-case nil
      (let ((buf (url-retrieve-synchronously
                  (gptel-agent-runtime--ollama-url "/api/tags") t t 1)))
        (when buf
          (kill-buffer buf)
          t))
    (error nil)))

(defun gptel-agent-runtime-start-ollama-if-needed ()
  "Start Ollama in the background if configured and not already running."
  (when (and gptel-agent-runtime-auto-start-ollama
             (executable-find gptel-agent-runtime-ollama-command)
             (not (gptel-agent-runtime-ollama-running-p)))
    (let ((process-environment (copy-sequence process-environment)))
      (when gptel-agent-runtime-ollama-models-directory
        (setenv "OLLAMA_MODELS"
                (expand-file-name gptel-agent-runtime-ollama-models-directory)))
      (start-process "ollama-serve" "*ollama-serve*"
                     gptel-agent-runtime-ollama-command "serve"))))

(defun gptel-agent-runtime-active-ollama-model ()
  "Return the first currently loaded Ollama model as a symbol, or nil.
This uses /api/ps, which reports loaded/running models. The function tolerates
both plist and vector shapes returned by `json-read'."
  (condition-case nil
      (let ((buf (url-retrieve-synchronously
                  (gptel-agent-runtime--ollama-url "/api/ps") t t 1)))
        (when buf
          (unwind-protect
              (with-current-buffer buf
                (goto-char (point-min))
                (when (re-search-forward "\n\n" nil t)
                  (let* ((json-object-type 'plist)
                         (json-array-type 'list)
                         (json-key-type 'keyword)
                         (data (json-read))
                         (models (plist-get data :models))
                         (first-model (car-safe models))
                         (name (plist-get first-model :name)))
                    (when (and (stringp name)
                               (not (string-empty-p name)))
                      (intern name)))))
            (kill-buffer buf))))
    (error nil)))

(defun my/gptel-model-id (model)
  "Return the symbol model id from MODEL, tolerating gptel metadata forms."
  (cond
   ((symbolp model) model)
   ((and (consp model) (symbolp (car model))) (car model))
   ((and (vectorp model) (> (length model) 0) (symbolp (aref model 0)))
    (aref model 0))
   (t model)))

(defun my/gptel-backend-model-symbols (backend)
  "Return BACKEND model ids as symbols, tolerating list/vector metadata."
  (when (and backend (fboundp 'gptel-backend-models))
    (mapcar #'my/gptel-model-id
            (append (gptel-backend-models backend) nil))))

;;;###autoload
(defun gptel-agent-runtime-use-default-local-model ()
  "Select the active or configured default local Ollama model when available."
  (interactive)
  (gptel-agent-runtime-start-ollama-if-needed)
  (when my/gptel-ollama-backend
    (let ((model (or (and gptel-agent-runtime-prefer-active-ollama-model
                          (gptel-agent-runtime-active-ollama-model))
                     gptel-agent-runtime-default-local-model)))
      (unless (member model (my/gptel-backend-model-symbols my/gptel-ollama-backend))
        (when (fboundp 'gptel-backend-models)
          (setf (gptel-backend-models my/gptel-ollama-backend)
                (append (gptel-backend-models my/gptel-ollama-backend)
                        (list `(,model :capabilities (tool-use json)))))))
      (setq gptel-backend my/gptel-ollama-backend
            gptel-model model)
      (when (fboundp 'my/gptel-sync-directive-for-current-runtime)
        (my/gptel-sync-directive-for-current-runtime))
      (when (fboundp 'my/gptel-sync-tools)
        (my/gptel-sync-tools))
      (message "gptel local model selected: %s%s"
               model
               (if (eq model gptel-agent-runtime-default-local-model)
                   (format " (%s)" gptel-agent-runtime-default-local-model-label)
                 " (active Ollama model)")))))

(defun my/gptel-register-model (name backend model)
  "Register NAME with BACKEND+MODEL in `my/gptel-backends'.
Overwrites an existing entry with the same name."
  (setq my/gptel-backends
        (cons (cons name (cons backend model))
              (cl-remove name my/gptel-backends
                         :key #'car :test #'equal))))

(provide 'gar-backend)

;;; gar-backend.el ends here
