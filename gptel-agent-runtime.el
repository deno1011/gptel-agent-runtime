;;; gptel-agent-runtime.el --- Emacs-native agent runtime on top of gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Denis Butic

;; Author: Denis Butic
;; Maintainer: Denis Butic
;; URL: https://github.com/deno1011/gptel-agent-runtime
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))
;; Keywords: convenience, tools, ai, gptel

;;; Commentary:

;; First package-shaped extraction of Denis Butic's Emacs/gptel agent runtime.
;; The implementation is intentionally monolithic for the first split so it can
;; be installed from Git and then refactored safely into smaller modules.
;;
;; Host configuration is still expected to define personal paths such as
;; `my/data-dir' before requiring this package.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar my/data-dir (expand-file-name "~/emacs/")
  "Personal data/config root supplied by the host Emacs configuration.
This fallback keeps the package loadable when it is required outside Denis's
normal init path.")

(defgroup gptel-agent-runtime nil
  "Emacs-native agent runtime built on top of gptel."
  :group 'applications
  :prefix "gptel-agent-runtime-")

(defconst gptel-agent-runtime-package-name "gptel-agent-runtime"
  "Candidate package name for the reusable AI agent runtime.")

(defconst gptel-agent-runtime-public-prefix "gptel-agent-runtime-"
  "Public symbol prefix reserved for reusable package code.")

(defconst gptel-agent-runtime-private-prefix "gptel-agent-runtime--"
  "Private helper prefix reserved for reusable package internals.")

(defcustom gptel-agent-runtime-enabled nil
  "When non-nil, enable the experimental agent runtime layer.
This switch is reserved for the future planner/executor loop. Existing gptel
chat, tools, and Response Executor behavior do not depend on it yet."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-max-iterations 8
  "Maximum number of observe/plan/act iterations in one agent run.
The limit prevents runaway loops once the planner/executor loop is added."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-require-confirmation-for-risky-actions t
  "When non-nil, require confirmation before risky tool actions.
Risk classification will be implemented in the safety layer. The default is
intentionally conservative for package-readiness."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-auto-execute-safe-actions t
  "When non-nil, auto-execute safe/read actions in autonomous runs.
Write, shell, and destructive actions still honor
`gptel-agent-runtime-require-confirmation-for-risky-actions'."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-memory-directory
  (expand-file-name "gptel-agent-runtime/" user-emacs-directory)
  "Directory for future persistent agent memory and session state."
  :type 'directory
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-default-role 'assistant
  "Default role used by future agent sessions.
Planned values include `assistant', `planner', `executor', `reviewer', and
`memory-curator'."
  :type '(choice (const :tag "Assistant" assistant)
                 (const :tag "Planner" planner)
                 (const :tag "Executor" executor)
                 (const :tag "Reviewer" reviewer)
                 (const :tag "Memory curator" memory-curator)
                 symbol)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-default-local-model 'qwen2.5-coder:7b
  "Default local model selected for gptel when Ollama is available."
  :type 'symbol
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-prefer-active-ollama-model t
  "When non-nil, select Ollama's currently loaded model before the fallback default.
The active model is read from Ollama's /api/ps endpoint. If no model is loaded,
or Ollama is not reachable yet, `gptel-agent-runtime-default-local-model' is
used instead."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-default-local-model-label
  "Qwen 2.5 Coder 7B (Ollama)"
  "Display label for `gptel-agent-runtime-default-local-model'."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-auto-start-ollama t
  "When non-nil, start the Ollama server automatically if it is not running."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-ollama-command "ollama"
  "Command used to start and manage Ollama."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-ollama-host "localhost:11434"
  "Host and port used by the local Ollama server."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-ollama-models-directory nil
  "Optional directory for Ollama model storage.
When non-nil it is exported as OLLAMA_MODELS before starting Ollama. This lets
the server find models downloaded to a non-default location."
  :type '(choice (const :tag "Use Ollama default" nil)
                 directory)
  :group 'gptel-agent-runtime)

(cl-defstruct (gptel-agent-runtime-task
               (:constructor gptel-agent-runtime-task-create))

"A single high-level task handled by the future agent runtime."
  id
  title
  goal
  status
  parent-id
  children
  created-at
  updated-at
  notes)

(cl-defstruct (gptel-agent-runtime-session
               (:constructor gptel-agent-runtime-session-create))
  "State for one future agent run."
  id
  role
  root-task
  current-task
  iteration
  observations
  decisions
  tool-results
  started-at
  updated-at)

(defun gptel-agent-runtime--timestamp ()
  "Return an ISO-like local timestamp for runtime state."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun gptel-agent-runtime-create-task (title goal &optional parent-id)
  "Create a task object with TITLE, GOAL, and optional PARENT-ID."
  (let ((now (gptel-agent-runtime--timestamp)))
    (gptel-agent-runtime-task-create
     :id (format "task-%s" (format-time-string "%Y%m%d%H%M%S%N"))
     :title title
     :goal goal
     :status 'new
     :parent-id parent-id
     :children nil
     :created-at now
     :updated-at now
     :notes nil)))

(defun gptel-agent-runtime-create-session (root-task &optional role)
  "Create a session around ROOT-TASK using ROLE or the default role."
  (let ((now (gptel-agent-runtime--timestamp)))
    (gptel-agent-runtime-session-create
     :id (format "session-%s" (format-time-string "%Y%m%d%H%M%S%N"))
     :role (or role gptel-agent-runtime-default-role)
     :root-task root-task
     :current-task root-task
     :iteration 0
     :observations nil
     :decisions nil
     :tool-results nil
     :started-at now
     :updated-at now)))

(defcustom gptel-agent-runtime-protected-paths
  nil
  "List of files or directories that agent tools must not modify.
Entries are expanded with `expand-file-name'. A directory protects all files
below it. This package-level list supplements local guards such as
`my/gptel-protected-files'."
  :type '(repeat file)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-risk-confirmation-level 'write
  "Minimum action risk that requires confirmation.
Allowed values are `safe', `read', `write', `shell', and `destructive'."
  :type '(choice (const :tag "Safe" safe)
                 (const :tag "Read" read)
                 (const :tag "Write" write)
                 (const :tag "Shell" shell)
                 (const :tag "Destructive" destructive))
  :group 'gptel-agent-runtime)

(defconst gptel-agent-runtime--risk-order
  '((safe . 0)
    (read . 1)
    (write . 2)
    (shell . 3)
    (destructive . 4))
  "Internal ordering for action risk levels.")

(defun gptel-agent-runtime--risk-value (risk)
  "Return numeric value for RISK."
  (or (alist-get risk gptel-agent-runtime--risk-order) 4))

(defun gptel-agent-runtime-risk-at-least-p (risk threshold)
  "Return non-nil when RISK is at least THRESHOLD."
  (>= (gptel-agent-runtime--risk-value risk)
      (gptel-agent-runtime--risk-value threshold)))

(defun gptel-agent-runtime--path-under-directory-p (path directory)
  "Return non-nil when PATH is inside DIRECTORY."
  (let ((path (file-truename (expand-file-name path)))
        (directory (file-name-as-directory
                    (file-truename (expand-file-name directory)))))
    (string-prefix-p directory path)))

(defun gptel-agent-runtime-protected-path-p (path)
  "Return non-nil when PATH is protected by runtime or local policy."
  (let ((expanded (expand-file-name path)))
    (or (and (fboundp 'my/gptel-protected-p)
             (my/gptel-protected-p expanded))
        (cl-some
         (lambda (protected)
           (let ((p (expand-file-name protected)))
             (if (file-directory-p p)
                 (gptel-agent-runtime--path-under-directory-p expanded p)
               (string= (file-truename expanded)
                        (file-truename p)))))
         gptel-agent-runtime-protected-paths))))

(defun gptel-agent-runtime-confirmation-required-p (risk)
  "Return non-nil when an action with RISK requires confirmation."
  (and gptel-agent-runtime-require-confirmation-for-risky-actions

(gptel-agent-runtime-risk-at-least-p
        risk gptel-agent-runtime-risk-confirmation-level)))

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
  notes)

(defvar gptel-agent-runtime-tool-registry nil
  "List of `gptel-agent-runtime-tool' entries registered for agent use.")

(defun gptel-agent-runtime-register-tool
    (name category risk description &rest plist)
  "Register tool metadata.
NAME is a string or symbol. CATEGORY and RISK are symbols. DESCRIPTION is a
human-readable summary. PLIST may include :package-ready-p, :local-only-p,
:gptel-tool, and :notes."
  (let* ((tool-name (if (symbolp name) (symbol-name name) name))
         (entry (gptel-agent-runtime-tool-create
                 :name tool-name
                 :category category
                 :risk risk
                 :description description
                 :package-ready-p (plist-get plist :package-ready-p)
                 :local-only-p (plist-get plist :local-only-p)
                 :gptel-tool (plist-get plist :gptel-tool)
                 :notes (plist-get plist :notes))))
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

(defun gptel-agent-runtime-result-ok
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

(defun gptel-agent-runtime-result-error
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

(cl-defstruct (gptel-agent-runtime-plan-step
               (:constructor gptel-agent-runtime-plan-step-create))
  "One planned step in a future agent run."
  id
  title
  rationale
  agent
  skills
  suggested-tool
  args
  risk
  status
  result
  observations
  reflections
  attempts)

(cl-defstruct (gptel-agent-runtime-plan
               (:constructor gptel-agent-runtime-plan-create))
  "A plan associated with a runtime task."
  id
  task-id
  status
  steps
  created-at
  updated-at)

(defun gptel-agent-runtime-create-plan (task &optional steps)
  "Create a plan for TASK with optional STEPS."
  (let ((now (gptel-agent-runtime--timestamp)))
    (gptel-agent-runtime-plan-create
     :id (format "plan-%s" (format-time-string "%Y%m%d%H%M%S%N"))
     :task-id (gptel-agent-runtime-task-id task)
     :status 'draft
     :steps steps
     :created-at now
     :updated-at now)))

(defun gptel-agent-runtime-create-plan-step
    (title rationale &optional suggested-tool risk &rest plist)
  "Create one draft plan step."
  (gptel-agent-runtime-plan-step-create
   :id (format "step-%s" (format-time-string "%Y%m%d%H%M%S%N"))
   :title title
   :rationale rationale
   :agent (plist-get plist :agent)
   :skills (plist-get plist :skills)
   :suggested-tool suggested-tool
   :args (plist-get plist :args)
   :risk (or risk 'safe)
   :status 'draft
   :result nil
   :observations nil
   :reflections nil
   :attempts 0))

(defun gptel-agent-runtime-plan-complete-p (plan)
  "Return non-nil when every step in PLAN is done."
  (cl-every
   (lambda (step)
     (eq (gptel-agent-runtime-plan-step-status step) 'done))
   (gptel-agent-runtime-plan-steps plan)))

(defun gptel-agent-runtime-next-plan-step (plan)
  "Return the first non-done step in PLAN."
  (cl-find-if
   (lambda (step)
     (not (memq (gptel-agent-runtime-plan-step-status step)
                '(done skipped cancelled))))
   (gptel-agent-runtime-plan-steps plan)))

(defcustom gptel-agent-runtime-memory-format 'sexp
  "Storage format for future runtime memory files.
Only `sexp' is implemented at this stage because it is easy to inspect from
Emacs and safe to evolve while the data model is still changing."
  :type '(choice (const :tag "S-expression" sexp))
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime-memory-ensure-directory ()
  "Ensure `gptel-agent-runtime-memory-directory' exists and return it."
  (make-directory gptel-agent-runtime-memory-directory t)
  gptel-agent-runtime-memory-directory)

(defun gptel-agent-runtime-memory-session-path (session)
  "Return the memory file path for SESSION."
  (expand-file-name
   (concat (gptel-agent-runtime-session-id session) ".el")
   (gptel-agent-runtime-memory-ensure-directory)))

(defun gptel-agent-runtime--struct-to-data (object)
  "Convert known runtime struct OBJECT into printable data."
  (cond
   ((gptel-agent-runtime-task-p object)
    `(:type task
      :id ,(gptel-agent-runtime-task-id object)
      :title ,(gptel-agent-runtime-task-title object)
      :goal ,(gptel-agent-runtime-task-goal object)
      :status ,(gptel-agent-runtime-task-status object)
      :parent-id ,(gptel-agent-runtime-task-parent-id object)
      :children ,(gptel-agent-runtime-task-children object)
      :created-at ,(gptel-agent-runtime-task-created-at object)
      :updated-at ,(gptel-agent-runtime-task-updated-at object)
      :notes ,(gptel-agent-runtime--struct-to-data
               (gptel-agent-runtime-task-notes object))))
   ((gptel-agent-runtime-plan-p object)
    `(:type plan
      :id ,(gptel-agent-runtime-plan-id object)
      :task-id ,(gptel-agent-runtime-plan-task-id object)
      :status ,(gptel-agent-runtime-plan-status object)
      :steps ,(mapcar #'gptel-agent-runtime--struct-to-data
                      (gptel-agent-runtime-plan-steps object))
      :created-at ,(gptel-agent-runtime-plan-created-at object)
      :updated-at ,(gptel-agent-runtime-plan-updated-at object)))
   ((gptel-agent-runtime-plan-step-p object)
    `(:type plan-step
      :id ,(gptel-agent-runtime-plan-step-id object)
      :title ,(gptel-agent-runtime-plan-step-title object)
      :rationale ,(gptel-agent-runtime-plan-step-rationale object)
      :agent ,(gptel-agent-runtime-plan-step-agent object)
      :skills ,(gptel-agent-runtime-plan-step-skills object)
      :tool ,(gptel-agent-runtime-plan-step-suggested-tool object)
      :args ,(gptel-agent-runtime-plan-step-args object)
      :risk ,(gptel-agent-runtime-plan-step-risk object)
      :status ,(gptel-agent-runtime-plan-step-status object)
      :result ,(gptel-agent-runtime--struct-to-data
                (gptel-agent-runtime-plan-step-result object))
      :observations ,(gptel-agent-runtime-plan-step-observations object)
      :reflections ,(gptel-agent-runtime-plan-step-reflections object)
      :attempts ,(gptel-agent-runtime-plan-step-attempts object)))
   ((gptel-agent-runtime-action-result-p object)
    `(:type action-result
      :status ,(gptel-agent-runtime-action-result-status object)
      :tool ,(gptel-agent-runtime-action-result-tool object)
      :output ,(gptel-agent-runtime-action-result-output object)
      :error ,(gptel-agent-runtime-action-result-error object)
      :warnings ,(gptel-agent-runtime-action-result-warnings object)
      :changed-files ,(gptel-agent-runtime-action-result-changed-files object)
      :changed-buffers ,(gptel-agent-runtime-action-result-changed-buffers object)
      :reflection-needed-p ,(gptel-agent-runtime-action-result-reflection-needed-p object)
      :metadata ,(gptel-agent-runtime-action-result-metadata object)))
   ((gptel-agent-runtime-session-p object)
    `(:type session
      :id ,(gptel-agent-runtime-session-id object)
      :role ,(gptel-agent-runtime-session-role object)
      :root-task ,(gptel-agent-runtime--struct-to-data
                   (gptel-agent-runtime-session-root-task object))
      :current-task ,(gptel-agent-runtime--struct-to-data
                      (gptel-agent-runtime-session-current-task object))
      :iteration ,(gptel-agent-runtime-session-iteration object)
      :observations ,(gptel-agent-runtime-session-observations object)
      :decisions ,(gptel-agent-runtime-session-decisions object)
      :tool-results ,(gptel-agent-runtime-session-tool-results object)
      :started-at ,(gptel-agent-runtime-session-started-at object)
      :updated-at ,(gptel-agent-runtime-session-updated-at object)))
   (t object)))

(defun gptel-agent-runtime-memory-write-session (session)
  "Write SESSION to its memory file and return the file path."
  (let ((path (gptel-agent-runtime-memory-session-path session))
        (print-length nil)
        (print-level nil))
    (with-temp-file path
      (insert ";;; gptel-agent-runtime session memory -*- mode: emacs-lisp; -*-\n")
      (prin1 (gptel-agent-runtime--struct-to-data session) (current-buffer))
      (insert "\n"))
    path))

(defcustom gptel-agent-runtime-enable-routing t
  "When non-nil, use the agent/skill router for new agent sessions."
  :type 'boolean
  :group 'gptel-agent-runtime)

(cl-defstruct (gptel-agent-runtime-agent
               (:constructor gptel-agent-runtime-agent-create))
  "Definition of one specialist agent role."
  name
  role
  description
  directive
  model-tags
  tool-categories
  default-skills
  system-prompt
  enabled-p
  metadata)

(cl-defstruct (gptel-agent-runtime-skill
               (:constructor gptel-agent-runtime-skill-create))
  "Definition of one reusable task skill."
  name
  summary
  triggers
  agent-names
  tool-categories
  instructions
  examples
  validation
  memory-key
  enabled-p
  metadata)

(defvar gptel-agent-runtime-agent-registry nil
  "Registered `gptel-agent-runtime-agent' definitions.")

(defvar gptel-agent-runtime-skill-registry nil
  "Registered `gptel-agent-runtime-skill' definitions.")

(defvar gptel-agent-runtime-last-route nil
  "Most recent route plist returned by `gptel-agent-runtime-route-task'.")

(defun gptel-agent-runtime--symbol-name (value)
  "Return a stable string name for VALUE."
  (cond
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t (format "%s" value))))

(defun gptel-agent-runtime-register-agent
    (name role description &rest plist)
  "Register an agent definition.
NAME and ROLE may be symbols or strings. DESCRIPTION is user-facing text.
PLIST accepts :directive, :model-tags, :tool-categories, :default-skills,
:system-prompt, :enabled-p, and :metadata."
  (let* ((agent-name (gptel-agent-runtime--symbol-name name))
         (agent (gptel-agent-runtime-agent-create
                 :name agent-name
                 :role role
                 :description description
                 :directive (or (plist-get plist :directive) role)
                 :model-tags (plist-get plist :model-tags)
                 :tool-categories (plist-get plist :tool-categories)
                 :default-skills (plist-get plist :default-skills)
                 :system-prompt (plist-get plist :system-prompt)
                 :enabled-p (if (plist-member plist :enabled-p)
                                (plist-get plist :enabled-p)
                              t)
                 :metadata (plist-get plist :metadata))))
    (setq gptel-agent-runtime-agent-registry
          (cons agent
                (cl-remove agent-name gptel-agent-runtime-agent-registry
                           :key #'gptel-agent-runtime-agent-name
                           :test #'equal)))
    agent))

(defun gptel-agent-runtime-find-agent (name)
  "Return registered agent NAME, or nil."
  (let ((agent-name (gptel-agent-runtime--symbol-name name)))
    (cl-find agent-name gptel-agent-runtime-agent-registry
             :key #'gptel-agent-runtime-agent-name
             :test #'equal)))

(defun gptel-agent-runtime-enabled-agents ()
  "Return all enabled registered agents."
  (cl-remove-if-not #'gptel-agent-runtime-agent-enabled-p
                    gptel-agent-runtime-agent-registry))

(defun gptel-agent-runtime-register-skill
    (name summary triggers &rest plist)
  "Register a reusable skill.
NAME may be a symbol or string. SUMMARY describes the skill. TRIGGERS is a list
of regexps or keywords matched against a task. PLIST accepts :agent-names,
:tool-categories, :instructions, :examples, :validation, :memory-key,
:enabled-p, and :metadata."
  (let* ((skill-name (gptel-agent-runtime--symbol-name name))
         (skill (gptel-agent-runtime-skill-create
                 :name skill-name
                 :summary summary
                 :triggers triggers
                 :agent-names (plist-get plist :agent-names)
                 :tool-categories (plist-get plist :tool-categories)
                 :instructions (plist-get plist :instructions)
                 :examples (plist-get plist :examples)
                 :validation (plist-get plist :validation)
                 :memory-key (plist-get plist :memory-key)
                 :enabled-p (if (plist-member plist :enabled-p)
                                (plist-get plist :enabled-p)
                              t)
                 :metadata (plist-get plist :metadata))))
    (setq gptel-agent-runtime-skill-registry
          (cons skill
                (cl-remove skill-name gptel-agent-runtime-skill-registry
                           :key #'gptel-agent-runtime-skill-name
                           :test #'equal)))
    skill))

(defun gptel-agent-runtime-find-skill (name)
  "Return registered skill NAME, or nil."
  (let ((skill-name (gptel-agent-runtime--symbol-name name)))
    (cl-find skill-name gptel-agent-runtime-skill-registry
             :key #'gptel-agent-runtime-skill-name
             :test #'equal)))

(defun gptel-agent-runtime-enabled-skills ()
  "Return all enabled registered skills."
  (cl-remove-if-not #'gptel-agent-runtime-skill-enabled-p
                    gptel-agent-runtime-skill-registry))

(defun gptel-agent-runtime--skill-matches-p (skill text)
  "Return non-nil when SKILL trigger matches TEXT."
  (let ((case-fold-search t))
    (cl-some
     (lambda (trigger)
       (cond
        ((symbolp trigger)
         (string-match-p (regexp-quote (symbol-name trigger)) text))
        ((stringp trigger)
         (string-match-p trigger text))
        (t nil)))
     (gptel-agent-runtime-skill-triggers skill))))

(defun gptel-agent-runtime-match-skills (text)
  "Return enabled skills whose triggers match TEXT."
  (cl-remove-if-not
   (lambda (skill)
     (gptel-agent-runtime--skill-matches-p skill text))
   (gptel-agent-runtime-enabled-skills)))

(defun gptel-agent-runtime--agent-score (agent text skills)
  "Return a simple routing score for AGENT given TEXT and matched SKILLS."
  (let* ((case-fold-search t)
         (name (gptel-agent-runtime-agent-name agent))
         (role (gptel-agent-runtime--symbol-name
                (gptel-agent-runtime-agent-role agent)))
         (description (or (gptel-agent-runtime-agent-description agent) ""))
         (skill-score
          (cl-count-if
           (lambda (skill)
             (member name (mapcar #'gptel-agent-runtime--symbol-name
                                  (gptel-agent-runtime-skill-agent-names skill))))
           skills)))
    (+ (if (string-match-p (regexp-quote role) text) 3 0)
       (if (and description
                (string-match-p (regexp-quote name) text)) 2 0)
       skill-score)))

(defun gptel-agent-runtime-route-task (text)
  "Route task TEXT to an agent and matching skills.
Returns a plist with :agent, :skills, :all-agents, and :reason."
  (let* ((skills (gptel-agent-runtime-match-skills text))
         (agents (gptel-agent-runtime-enabled-agents))
         (scored (mapcar
                  (lambda (agent)
                    (cons agent
                          (gptel-agent-runtime--agent-score agent text skills)))
                  agents))
         (best (car (sort scored (lambda (a b) (> (cdr a) (cdr b))))))
         (agent (or (car-safe best)
                    (gptel-agent-runtime-find-agent
                     gptel-agent-runtime-default-role)
                    (car agents)))
         (route (list
                 :agent agent
                 :skills skills
                 :all-agents agents
                 :reason
                 (format "Matched %d skill(s); selected %s."
                         (length skills)
                         (if agent
                             (gptel-agent-runtime-agent-name agent)
                           "<none>")))))
    (setq gptel-agent-runtime-last-route route)
    route))

(defun gptel-agent-runtime-route-summary (text)
  "Return a human-readable route summary for TEXT."
  (let* ((route (gptel-agent-runtime-route-task text))
         (agent (plist-get route :agent))
         (skills (plist-get route :skills)))
    (format "Agent: %s\nRole: %s\nSkills: %s\nReason: %s"
            (if agent (gptel-agent-runtime-agent-name agent) "<none>")
            (if agent (gptel-agent-runtime-agent-role agent) "<none>")
            (if skills
                (mapconcat #'gptel-agent-runtime-skill-name skills ", ")
              "<none>")
            (plist-get route :reason))))

(defun gptel-agent-runtime-describe-route (text)
  "Display the agent/skill route for TEXT."
  (interactive "sRoute task: ")
  (message "%s" (gptel-agent-runtime-route-summary text)))

(defun gptel-agent-runtime-agent-directive (agent)
  "Return directive symbol for AGENT."
  (or (and agent (gptel-agent-runtime-agent-directive agent))
      (if (my/gptel-local-runtime-p)
          'emacs-local-assistant
        'emacs-assistant)))

(defun gptel-agent-runtime-skill-instructions (skills)
  "Return prompt instructions for SKILLS."
  (when skills
    (concat
     "Relevant skills:\n"
     (mapconcat
      (lambda (skill)
        (format "- %s: %s\n  Instructions: %s\n  Validation: %s"
                (gptel-agent-runtime-skill-name skill)
                (or (gptel-agent-runtime-skill-summary skill) "")
                (or (gptel-agent-runtime-skill-instructions skill) "")
                (or (gptel-agent-runtime-skill-validation skill) "")))
      skills
      "\n"))))

(defun gptel-agent-runtime-apply-route-to-current-buffer (text)
  "Apply route for TEXT to the current gptel buffer.
This sets the local directive and appends skill instructions to the active
system message. It is intentionally lightweight; the planner loop will later
consume the full route object."
  (let* ((route (gptel-agent-runtime-route-task text))
         (agent (plist-get route :agent))
         (skills (plist-get route :skills))
         (directive (gptel-agent-runtime-agent-directive agent))
         (base (alist-get directive gptel-directives))
         (skill-text (gptel-agent-runtime-skill-instructions skills)))
    (when base
      (setq-local gptel--system-message
                  (if skill-text
                      (concat base "\n\n" skill-text)
                    base)))
    route))

(defun gptel-agent-runtime-register-default-agents-and-skills ()
  "Register built-in starter agents and skills.
These defaults are intentionally small and transparent; users can override or
extend them later from their private config."
  (interactive)
  (gptel-agent-runtime-register-agent
   'assistant 'assistant
   "General Emacs assistant for direct user-facing answers."
   :directive 'emacs-local-assistant
   :tool-categories '(org files buffers web export code)
   :default-skills '(org-output web-research inline-rendering))
  (gptel-agent-runtime-register-agent
   'planner 'planner
   "Breaks broad goals into explicit steps and selects tools."
   :directive 'emacs-planner
   :tool-categories '(context tools))
  (gptel-agent-runtime-register-agent
   'executor 'executor
   "Runs concrete Emacs, file, shell, and Org actions."
   :directive 'emacs-local-assistant
   :tool-categories '(org files buffers code export))
  (gptel-agent-runtime-register-agent
   'reviewer 'reviewer
   "Checks results, looks for failures, and requests fixes."
   :directive 'emacs-local-assistant
   :tool-categories '(context files code))
  (gptel-agent-runtime-register-agent
   'memory-curator 'memory-curator
   "Records durable lessons, preferences, and strategy notes."
   :directive 'emacs-local-assistant
   :tool-categories '(memory org files))

  (gptel-agent-runtime-register-skill
   'inline-rendering
   "Create inline Org output for math, plots, diagrams, and generated files."
   '("plot" "graph" "diagram" "inline" "latex" "math" "3d")
   :agent-names '("assistant" "executor")
   :tool-categories '(code export)
   :instructions "Return finished Org content with LaTeX, executable Babel blocks, :file headers for images, #+RESULTS:, and [[file:...]] links."
   :validation "The response contains executable Org and any image block has a :file result link.")
  (gptel-agent-runtime-register-skill
   'web-research
   "Search and fetch current information before answering."
   '("web" "internet" "current" "latest" "today" "rules" "law" "regulation")
   :agent-names '("assistant" "planner")
   :tool-categories '(web)
   :instructions "Use web_search first, fetch official or primary sources, then cite source URLs."
   :validation "Answer cites URLs used for current facts.")
  (gptel-agent-runtime-register-skill
   'org-task-management
   "Read and update Org TODOs, agenda files, and task state."
   '("todo" "task" "agenda" "deadline" "schedule" "org")
   :agent-names '("assistant" "executor")
   :tool-categories '(org)
   :instructions "Use Org tools for task inspection and mutation; protect config files."
   :validation "Changed Org state is saved and reported.")
  (gptel-agent-runtime-register-skill
   'code-change
   "Inspect, edit, test, and review code changes."
   '("code" "repo" "test" "bug" "refactor" "implement" "fix")
   :agent-names '("planner" "executor" "reviewer")
   :tool-categories '(files code context)
   :instructions "Inspect relevant files first, make scoped edits, run appropriate checks, and summarize verification."
   :validation "Relevant tests or syntax checks were run, or the reason they were not run is stated.")
  (gptel-agent-runtime-register-skill
   'memory-update
   "Record reusable lessons and strategy updates."
   '("remember" "memory" "handover" "lesson" "strategy" "skill")
   :agent-names '("memory-curator")
   :tool-categories '(memory org files)
   :instructions "Write concise durable lessons to the appropriate memory or handover file."
   :validation "Memory update is committed or explicitly reported.")
  (list :agents gptel-agent-runtime-agent-registry
        :skills gptel-agent-runtime-skill-registry))

(gptel-agent-runtime-register-default-agents-and-skills)

(use-package gptel
  :ensure t
  :demand t
  :config
  (setq gptel-default-mode 'org-mode))

;; Provider constructors are defined in provider modules, not always in the
;; base gptel feature. Require them before backend construction so partial
;; reloads with M-x load-file cannot stop before tools are registered.
(require 'gptel)
(require 'gptel-anthropic nil t)
(require 'gptel-openai nil t)
(require 'gptel-ollama nil t)
(require 'gptel-gemini nil t)

(defvar my/gptel-backends nil
  "Alist of (DISPLAY-NAME . (BACKEND . MODEL)) for all backends.")

(defvar my/gptel-ollama-backend nil
  "The registered Ollama backend, when Ollama is installed.")

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
      (my/gptel-sync-directive-for-current-runtime)
      (my/gptel-sync-tools)
      (message "gptel local model selected: %s%s"
               model
               (if (eq model gptel-agent-runtime-default-local-model)
                   (format " (%s)" gptel-agent-runtime-default-local-model-label)
                 " (active Ollama model)")))))

;; -- Anthropic / Claude -----------------------------------------------
(let ((backend (gptel-make-anthropic "Claude"
                  :stream t
                  :key (lambda () (getenv "ANTHROPIC_API_KEY")))))
  (setq my/gptel-backends
        `(("Claude Opus 4.7"    ,backend . claude-opus-4-7)
          ("Claude Sonnet 4.6"  ,backend . claude-sonnet-4-6)
          ("Claude Haiku 4.5"   ,backend . claude-haiku-4-5-20251001)))
  ;; Preliminary default (overridden below by LM Studio)
  (setq gptel-backend backend
        gptel-model   'claude-opus-4-7))

;; -- OpenAI / ChatGPT -------------------------------------------------
;; Set OPENAI_API_KEY in secrets.el: (setenv "OPENAI_API_KEY" "sk-...")
;; gptel 0.9.9.5 automatically uses the Responses API for api.openai.com
;; (/v1/responses). Force Chat Completions via an explicit endpoint:
(let ((backend (gptel-make-openai "ChatGPT"
                  :stream t
                  :host "api.openai.com"
                  :endpoint "/v1/chat/completions"
                  :key (lambda () (getenv "OPENAI_API_KEY")))))
  (setq my/gptel-backends
        (append my/gptel-backends
                `(("GPT-4o"           ,backend . gpt-4o)
                  ("GPT-4o-mini"       ,backend . gpt-4o-mini)
                  ("o3-mini"           ,backend . o3-mini)
                  ("o4-mini"           ,backend . o4-mini)))))

;; -- Google Gemini ----------------------------------------------------
;; Set GEMINI_API_KEY in secrets.el: (setenv "GEMINI_API_KEY" "AIza...")
;; Commented out until key is available:
;; (let ((backend (gptel-make-gemini "Gemini"
;;                  :stream t
;;                  :key (lambda () (getenv "GEMINI_API_KEY")))))
;;   (setq my/gptel-backends
;;         (append my/gptel-backends
;;                 `(("Gemini 2.0 Flash" ,backend . gemini-2.0-flash)
;;                   ("Gemini 2.5 Pro"   ,backend . gemini-2.5-pro)))))

;; -- LM Studio (local, OpenAI-compatible) ----------------------------
;; LM Studio must be running: Sidebar → Local Server → Start Server
;; Port: 1234 (default). No API key required.
;; Verify model IDs with: curl http://localhost:1234/v1/models
(let ((backend (gptel-make-openai "LM Studio"
                  :stream t
                  :protocol "http"
                  :host "localhost:1234"
                  :endpoint "/v1/chat/completions"
                  :key "lm-studio"
                  :models '(mistralai/ministral-3-14b-reasoning
                            deepseek-r1-distill-qwen-7b
                            gemma-4-31b-it
                            gemma-3-12b-it))))
  (setq my/gptel-backends
        (append my/gptel-backends
                `(("Ministral 3B 14B Reasoning (LM Studio)" ,backend . mistralai/ministral-3-14b-reasoning)
                  ("DeepSeek R1 7B (LM Studio)"             ,backend . deepseek-r1-distill-qwen-7b)
                  ("Gemma 4 31B (LM Studio)"                ,backend . gemma-4-31b-it)
                  ("Gemma 3 12B Q4 (LM Studio)"             ,backend . gemma-3-12b-it))))
  ;; Default: LM Studio (local, private, free)
  ;; If server is offline: C-c M → select another backend/model.
  (setq gptel-backend backend
        gptel-model   'mistralai/ministral-3-14b-reasoning))

;; -- MLX (local, Apple Silicon, via mlx-lm standalone server) --------
;; Start server: mlx_lm.server --model mlx-community/Qwen3-14B-4bit --port 8080
;; Models download automatically from HuggingFace on first run.
(let ((backend (gptel-make-openai "MLX"
                  :stream t
                  :protocol "http"
                  :host "localhost:8080"
                  :endpoint "/v1/chat/completions"
                  :key "mlx"
                  :models '(mlx-community/Qwen3-14B-4bit
                            mlx-community/gemma-3-12b-it-4bit))))
  (setq my/gptel-backends
        (append my/gptel-backends
                `(("Qwen3 14B (MLX)"    ,backend . mlx-community/Qwen3-14B-4bit)
                  ("Gemma 3 12B (MLX)"  ,backend . mlx-community/gemma-3-12b-it-4bit)))))

;; -- Ollama (local) ---------------------------------------------------
;; Only activated when `ollama' is found in PATH.
;; Install models first: ollama pull <name>
(when (executable-find "ollama")
  (gptel-agent-runtime-start-ollama-if-needed)
  (let ((backend (gptel-make-ollama "Ollama"
                   :stream t
                   :host gptel-agent-runtime-ollama-host
                   :models '((llama3.2 :capabilities (tool-use json))
                              (mistral :capabilities (tool-use json))
                              phi3
                              (qwen2.5 :capabilities (tool-use json))
                              (qwen2.5-coder:7b :capabilities (tool-use json))
                              (deepseek-r1 :capabilities (tool-use json))))))
    (setq my/gptel-ollama-backend backend)
    (setq my/gptel-backends
          (append my/gptel-backends
                  `(("Llama 3.2 (Ollama)"    ,backend . llama3.2)
                    ("Mistral (Ollama)"       ,backend . mistral)
                    ("DeepSeek R1 (Ollama)"   ,backend . deepseek-r1)
                    ("Qwen 2.5 Coder 7B (Ollama)" ,backend . qwen2.5-coder:7b)
                    ("Qwen 2.5 (Ollama)"      ,backend . qwen2.5))))))

(defun my/gptel-register-model (name backend model)
  "Register NAME with BACKEND+MODEL in `my/gptel-backends'.
Overwrites an existing entry with the same name."
  (setq my/gptel-backends
        (cons (list name backend . model)
              (cl-remove name my/gptel-backends
                         :key #'car :test #'equal))))

(defvar my/gptel-local-model-pattern
  "\\(Ollama\\|LM Studio\\|MLX\\)"
  "Regexp matching model display names that should use the local directive.")

(defvar my/gptel-local-runtime-pattern
  "\\(Ollama\\|LM Studio\\|MLX\\|qwen2\\.5\\|qwen3\\|llama\\|mistral\\|deepseek-r1\\)"
  "Regexp matching active backend/model values that should use the local directive.")

(defun my/gptel-directive-for-choice (choice)
  "Return the directive symbol that should be used for model CHOICE."
  (if (string-match-p my/gptel-local-model-pattern choice)
      'emacs-local-assistant
    'emacs-assistant))

(defun my/gptel-local-runtime-p ()
  "Return non-nil when the active gptel backend/model is local."
  (let ((backend-name (condition-case nil
                          (if (and (boundp 'gptel-backend)
                                   (fboundp 'gptel-backend-name))
                              (format "%s" (gptel-backend-name gptel-backend))
                            (format "%S" gptel-backend))
                        (error (format "%S" gptel-backend))))
        (model-name (format "%S" (my/gptel-model-id gptel-model))))
    (string-match-p my/gptel-local-runtime-pattern
                    (concat backend-name " " model-name))))

(defun my/gptel-directive-for-current-runtime ()
  "Return the directive symbol for the active gptel backend/model."
  (if (my/gptel-local-runtime-p)
      'emacs-local-assistant
    'emacs-assistant))

(defun my/gptel-sync-directive-for-current-runtime ()
  "Set `gptel--system-message' according to the active backend/model."
  (let* ((directive (my/gptel-directive-for-current-runtime))
         (system-message (alist-get directive gptel-directives)))
    (when system-message
      (setq-local gptel--system-message system-message))
    directive))

(defun my/gptel-tools-all ()
  "Return list of all registered gptel-tool structs.
gptel--known-tools is a two-level alist: (category . ((name . struct) ...))."
  (when (and (boundp 'gptel--known-tools)
             (fboundp 'gptel-tool-p))
    (cl-loop for (_cat . tools) in gptel--known-tools
             append (cl-loop for (_name . tool) in tools
                             when (gptel-tool-p tool) collect tool))))

(defun my/gptel-sync-tools ()
  "Enable all registered gptel tools in the current buffer."
  (when (boundp 'gptel--known-tools)
    (setq-local gptel-use-tools t)
    (setq-local gptel-tools (my/gptel-tools-all))))

(defun my/gptel-select-model ()
  "Select backend+model — sets globally AND in the active gptel buffer."
  (interactive)
  (let* ((choice  (completing-read
                   (format "Model [current: %s]: " gptel-model)
                   my/gptel-backends nil t))
         (entry   (assoc choice my/gptel-backends))
         (backend (cadr entry))
         (model   (my/gptel-model-id (cddr entry)))
         (directive (my/gptel-directive-for-choice choice))
         (system-message (alist-get directive gptel-directives)))
    ;; Set globally (applies to new gptel sessions)
    (setq gptel-backend backend
          gptel-model   model)
    (when system-message
      (setq gptel--system-message system-message))
    ;; Switch all running gptel buffers as well
    (dolist (buf (buffer-list))
      (when (buffer-local-value 'gptel-mode buf)
        (with-current-buffer buf
          (setq-local gptel-backend backend
                      gptel-model   model)
          (when system-message
            (setq-local gptel--system-message system-message)))))
    (message "→ %s  (%s, directive: %s)" choice model directive)))

;; C-c M  — quick model switch in the current buffer
(global-set-key (kbd "C-c M") #'my/gptel-select-model)

(defun my/gptel-mode-line ()
  "Show the active gptel model in the mode line."
  (when (bound-and-true-p gptel-mode)
    (format " [%s]" gptel-model)))

(defun my/gptel-current-directive-name ()
  "Return the directive symbol that matches the current system message."
  (let ((current (and (boundp 'gptel--system-message) gptel--system-message)))
    (car (seq-find (lambda (entry)
                     (equal (cdr entry) current))
                   gptel-directives))))

(defun my/gptel-status ()
  "Display active gptel backend, model, directive, and tool count."
  (interactive)
  (message "gptel model=%s directive=%s use-tools=%s tools=%s web-tools=%s backend=%s"
           (if (boundp 'gptel-model) gptel-model "<unset>")
           (or (my/gptel-current-directive-name) "<custom/unknown>")
           (if (boundp 'gptel-use-tools) gptel-use-tools "<unset>")
           (if (boundp 'gptel-tools) (length gptel-tools) 0)
           (if (boundp 'gptel-tools)
               (cl-count-if
                (lambda (tool)
                  (member (gptel-tool-name tool)
                          '("web_search" "web_fetch_text"
                            "web_extract_images" "web_fetch_image")))
                gptel-tools)
             0)
           (if (boundp 'gptel-backend) gptel-backend "<unset>")))

(defun my/gptel-sync-and-status ()
  "Synchronize the directive for the active runtime and display status."
  (interactive)
  (let ((directive (my/gptel-sync-directive-for-current-runtime)))
    (my/gptel-sync-tools)
    (message "gptel model=%s synced-directive=%s use-tools=%s tools=%s web-tools=%s backend=%s"
             (if (boundp 'gptel-model) gptel-model "<unset>")
             directive
             (if (boundp 'gptel-use-tools) gptel-use-tools "<unset>")
             (if (boundp 'gptel-tools) (length gptel-tools) 0)
             (if (boundp 'gptel-tools)
                 (cl-count-if
                  (lambda (tool)
                    (member (gptel-tool-name tool)
                            '("web_search" "web_fetch_text"
                              "web_extract_images" "web_fetch_image")))
                  gptel-tools)
               0)
             (if (boundp 'gptel-backend) gptel-backend "<unset>"))))

(global-set-key (kbd "C-c G s") #'my/gptel-status)
(global-set-key (kbd "C-c G S") #'my/gptel-sync-and-status)

(unless (member '(:eval (my/gptel-mode-line)) mode-line-format)
  (setq mode-line-format
        (append mode-line-format '((:eval (my/gptel-mode-line))))))

(cond
  ;; macOS: pngpaste via brew
  ((and (eq system-type 'darwin)
        (not (executable-find "pngpaste"))
        (executable-find "brew"))
   (my/brew-install-and-log "formula" "pngpaste" "install" "pngpaste")
   (message "pngpaste not found — installing via brew in background. Restart Emacs when done."))
  ;; Linux/Docker: xclip via apt — try sudo, fall back to plain apt-get
  ((and (eq system-type 'gnu/linux)
        (not (executable-find "xclip")))
   (condition-case nil
       (let ((cmd (if (executable-find "sudo") "sudo" "apt-get"))
             (args (if (executable-find "sudo")
                       '("apt-get" "install" "-y" "xclip")
                     '("install" "-y" "xclip"))))
         (apply #'start-process "install-xclip" "*install-xclip*" cmd args)
         (message "xclip not found — installing via apt in background. Restart Emacs when done."))

(error (message "xclip not found — install manually: apt-get install xclip")))))

(defcustom my/gptel-image-dir
  (expand-file-name "gptel-images" user-emacs-directory)
  "Directory for images inserted via `my/insert-clipboard-image'."
  :type 'directory
  :group 'claude-executor)

(defcustom my/gptel-image-max-dim 1600
  "Maximum edge length in pixels.
Larger images are resized via sips. iPhone photos (4032×3024)
as PNG are ~15 MB → resize to 1600 px edge + optional JPEG: <500 KB.
Anthropic limit is 5 MB raw, but Base64 encoding (+33%) hits that at
~3.75 MB. Stay well below that to be safe."
  :type 'integer
  :group 'claude-executor)

(defcustom my/gptel-image-max-bytes (* 2 1024 1024)
  "Soft-limit image size in bytes (2 MB).
If exceeded after resize → convert to JPEG q=85.
Conservative due to Base64 overhead (~33%): 2 MB raw → ~2.7 MB encoded,
safely below the Anthropic 5 MB limit."
  :type 'integer
  :group 'claude-executor)

(with-eval-after-load 'org-download
  (cond
    ((executable-find "pngpaste")
     (setq org-download-screenshot-method "pngpaste %s"))
    ((executable-find "xclip")
     (setq org-download-screenshot-method "xclip -selection clipboard -t image/png -o > %s")))
  (setq org-download-image-dir my/gptel-image-dir
        org-download-method    'directory
        org-download-heading-lvl nil))

(defun my/--shrink-image (path)
  "Shrink PATH if necessary.
1. Limit edge length to `my/gptel-image-max-dim' (in-place).
2. If the file still exceeds `my/gptel-image-max-bytes': convert
   to JPEG q=85, replacing the original file.
Returns the final path (may change to .jpg on JPEG conversion)."
  (when (and (executable-find "sips") (file-exists-p path))
    ;; 1. Limit edge length to max
    (call-process "sips" nil nil nil
                  "-Z" (number-to-string my/gptel-image-max-dim)
                  path "--out" path)
    ;; 2. Convert to JPEG if needed
    (when (and (file-exists-p path)
               (> (nth 7 (file-attributes path)) my/gptel-image-max-bytes))
      (let* ((dir  (file-name-directory path))
             (base (file-name-sans-extension (file-name-nondirectory path)))
             (jpeg (expand-file-name (concat base ".jpg") dir)))
        (call-process "sips" nil nil nil
                      "-s" "format" "jpeg"
                      "-s" "formatOptions" "85"
                      path "--out" jpeg)
        (when (and (file-exists-p jpeg)
                   (> (nth 7 (file-attributes jpeg)) 0))
          (delete-file path)
          (setq path jpeg)))))
  path)

(defun my/--clipboard-to-file (path)
  "Save clipboard image to PATH using the available backend.
macOS: pngpaste. Linux/XQuartz: xclip.
Returns t on success, nil if no backend available or clipboard empty."
  (cond
    ((executable-find "pngpaste")
     (= 0 (call-process "pngpaste" nil nil nil path)))
    ((executable-find "xclip")
     ;; XQuartz bridges the macOS clipboard to X11 on focus — click the
     ;; Emacs window after copying on iPhone to trigger the sync first.
     (= 0 (shell-command
           (format "xclip -selection clipboard -t image/png -o > %s"
                   (shell-quote-argument path)))))
    (t nil)))

(defun my/insert-clipboard-image (&optional name)
  "Save clipboard image, shrink if needed, insert as org link and attach to gptel.
Uses pngpaste on macOS or xclip on Linux (XQuartz).
If NAME is nil or empty → timestamp filename."
  (interactive
   (list (read-string "Filename (without extension, Enter = timestamp): " "")))
  (unless (or (executable-find "pngpaste") (executable-find "xclip"))
    (user-error (if (eq system-type 'darwin)
                    "pngpaste missing — run: brew install pngpaste"
                  "xclip missing — run: sudo apt-get install xclip")))
  (make-directory my/gptel-image-dir t)
  (let* ((basename (if (or (null name) (string-empty-p name))
                       (format "img-%s" (format-time-string "%Y%m%d-%H%M%S"))
                     name))
         (raw-path (expand-file-name (concat basename ".png")
                                     my/gptel-image-dir))
         (ok       (my/--clipboard-to-file raw-path))
         (size     (and ok (file-exists-p raw-path)
                        (nth 7 (file-attributes raw-path)))))
    (cond
     ((and ok size (> size 0))
      (let* ((final-path (my/--shrink-image raw-path))
             (final-size (nth 7 (file-attributes final-path))))
        (insert (format "[[file:%s]]\n" final-path))
        (when (derived-mode-p 'org-mode)
          (org-display-inline-images t t))
        (if (require 'gptel-context nil 'noerror)
            (progn
              (gptel-context-add-file final-path)
              (message "Image inserted + attached to gptel: %s (%s)"
                       (file-name-nondirectory final-path)
                       (file-size-human-readable final-size)))
          (message "Image inserted: %s (gptel-context not available)"
                   final-path))))
     (t
      (when (file-exists-p raw-path) (delete-file raw-path))
      (user-error "No image in clipboard — on Linux/XQuartz: click Emacs window after copying to trigger clipboard sync")))))

(defun my/gptel-attach-image-at-point ()
  "Find the org file: link at/around point and attach PATH to the
next gptel request. Shrinks first if necessary."
  (interactive)
  (require 'gptel-context)
  (let ((ctx (org-element-context)))
    (if (and (eq (org-element-type ctx) 'link)
             (string= (org-element-property :type ctx) "file"))
        (let ((path (expand-file-name
                     (org-element-property :path ctx))))
          (if (file-exists-p path)
              (let ((final-path (my/--shrink-image path)))
                (gptel-context-add-file final-path)
                (message "Attached to gptel: %s (%s)"
                         (file-name-nondirectory final-path)
                         (file-size-human-readable
                          (nth 7 (file-attributes final-path)))))
            (user-error "File not found: %s" path)))
      (user-error "No file: link at point"))))

(with-eval-after-load 'gptel
  (define-key gptel-mode-map (kbd "C-c i") #'my/insert-clipboard-image)
  (define-key gptel-mode-map (kbd "C-c I") #'my/gptel-attach-image-at-point))

;; Also available globally — in case you capture outside gptel-mode
(global-set-key (kbd "C-c i") #'my/insert-clipboard-image)
(global-set-key (kbd "C-c I") #'my/gptel-attach-image-at-point)

(require 'url)
(require 'shr)
(require 'dom)

(defcustom my/web-fetch-timeout 30
  "Timeout in seconds for `my/web-fetch'."
  :type 'integer
  :group 'claude-executor)

(defcustom my/web-user-agent "Emacs-Gptel-Agent-Helper"
  "User-Agent string for web requests."
  :type 'string
  :group 'claude-executor)

(defun my/web-fetch (url)
  "Fetch URL synchronously, return body as string.
Signals an error on HTTP >= 400 or timeout."
  (let ((url-user-agent my/web-user-agent))
    (with-current-buffer
        (url-retrieve-synchronously url t t my/web-fetch-timeout)
      (goto-char (point-min))
      (unless (re-search-forward "\r?\n\r?\n" nil t)
        (kill-buffer)
        (error "No HTTP body in response from %s" url))
      (let ((body (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer)
        body))))

(defun my/web-html (url)
  "Fetch URL and return a parsed DOM tree."
  (with-temp-buffer
    (insert (my/web-fetch url))
    (libxml-parse-html-region (point-min) (point-max))))

(defun my/web-text (url &optional max-chars)
  "Fetch URL, render as readable plain text via shr.
If MAX-CHARS is set: truncate to MAX-CHARS characters."
  (let ((dom              (my/web-html url))
        (shr-width        80)
        (shr-use-fonts    nil)
        (shr-inhibit-images t))
    (with-temp-buffer
      (shr-insert-document dom)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (if (and max-chars (> (length text) max-chars))
            (concat (substring text 0 max-chars) "\n…[truncated]")
          text)))))

(defun my/web-search-ddg (query &optional limit)
  "DuckDuckGo HTML search. Returns list of (TITLE . URL).
LIMIT defaults to 5."
  (let* ((url    (format "https://html.duckduckgo.com/html/?q=%s"
                         (url-hexify-string query)))
         (dom    (my/web-html url))
         (limit  (or limit 5))
         (anchors (dom-by-tag dom 'a))
         (results '()))
    (dolist (a anchors)
      (let ((class (or (dom-attr a 'class) ""))
            (href  (dom-attr a 'href))
            (title (string-trim (dom-text a))))
        (when (and href
                   (string-match-p "result__a\\|result__url" class)
                   (not (string-empty-p title)))
          (let ((real-url
                 (cond
                  ((string-match "uddg=\\([^&]+\\)" href)
                   (url-unhex-string (match-string 1 href)))
                  ((string-prefix-p "http" href) href)
                  (t (concat "https:" href)))))
            (cl-pushnew (cons title real-url) results
                        :test (lambda (a b) (equal (cdr a) (cdr b))))))))
    (seq-take (nreverse results) limit)))

(defun my/web-fetch-image (url &optional dir)
  "Download image from URL to DIR (default temporary-file-directory).
Returns local path."
  (let* ((ext  (or (file-name-extension (url-filename
                                          (url-generic-parse-url url)))
                   "png"))
         (base (format "gptel-img-%s" (format-time-string "%s%N")))
         (path (expand-file-name (concat base "." ext)
                                 (or dir temporary-file-directory))))
    (url-copy-file url path t)
    path))

(defun my/web-extract-images (url &optional limit)
  "Return absolute image URLs from a page, max LIMIT (default 10)."
  (let* ((dom   (my/web-html url))
         (imgs  (dom-by-tag dom 'img))
         (limit (or limit 10))
         (urls  '()))
    (dolist (img imgs)
      (let ((src (dom-attr img 'src)))
        (when (and src (not (string-prefix-p "data:" src)))
          (push (url-expand-file-name src url) urls))))
    (seq-take (nreverse urls) limit)))

(defun my/insert-image-inline (file-or-url)
  "Append FILE-OR-URL as an org image link to the current buffer end.
If FILE-OR-URL is a URL it is downloaded to a temp location first.
In org-mode `org-display-inline-images' is triggered."
  (let ((file (if (string-match-p "^https?://" file-or-url)
                  (my/web-fetch-image file-or-url)
                file-or-url)))
    (save-excursion
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "[[file:%s]]\n" file)))
    (when (derived-mode-p 'org-mode)
      (org-display-inline-images t t))
    file))

(use-package gptel
  :ensure t)

;;; claude-executor.el — Auto-execution hooks for AI model responses in Emacs

(require 'org)
(require 'ob)
(require 'cl-lib)

(defgroup claude-executor nil
  "Auto-execution of code blocks in assistant responses.
The `claude-executor' symbol prefix is kept for compatibility with earlier
configuration versions; the implementation is model-neutral."
  :group 'gptel-agent-runtime)

;;; --- General Switches ----------------------------------------------

(defcustom claude-executor-auto-execute nil
  "Automatically execute Babel blocks, exec-tags and auto-commands.
WARNING: security risk, off by default.
Does NOT affect AUTORUN elisp blocks — those always run when the
mode is active (with confirmation if `claude-executor-confirm-before-execute')."
  :type 'boolean
  :group 'claude-executor)

(defcustom claude-executor-confirm-before-execute nil
  "Require confirmation before each execution.
Applies to Babel blocks and AUTORUN elisp blocks."
  :type 'boolean
  :group 'claude-executor)

;;; --- Babel Block Configuration -------------------------------------

(defcustom claude-executor-allowed-languages
  '("python" "sh" "bash" "elisp" "R" "ruby" "js")
  "Languages for which Babel auto-execution is allowed.
Checked in `claude-executor--execute-babel-block'."
  :type '(repeat string)
  :group 'claude-executor)

;;; --- Pattern-Based Auto Commands -----------------------------------

(defcustom claude-executor-auto-commands nil
  "Alist of (REGEX . COMMAND) for automatic shell commands.
When REGEX matches in the response, COMMAND is executed.
Example:
  '((\"pip install \\\\(.*\\\\)\" . \"pip install \\\\1\"))"
  :type '(alist :key-type regexp :value-type string)
  :group 'claude-executor)

;;; --- AUTORUN Configuration -----------------------------------------

(defcustom claude-executor-auto-execute-elisp nil
  "Reserved flag for future elisp auto-eval control.
Currently AUTORUN execution is coupled to `claude-executor-mode' and
`claude-executor-confirm-before-execute'."
  :type 'boolean
  :group 'claude-executor)

(defcustom claude-executor-elisp-tag "AUTORUN"
  "Tag that marks automatic elisp execution.
The assistant must write ~#+begin_src elisp :AUTORUN~ in responses.
Can be renamed via this custom variable (e.g. \"RUN\")."
  :type 'string
  :group 'claude-executor)

(defcustom claude-executor-allowed-functions nil
  "Optional whitelist of allowed functions for AUTORUN eval.
- nil  → no restriction (any elisp call is allowed).
- list → AUTORUN code that calls a function not in the list is
        rejected and logged in *Assistant Actions*."
  :type '(repeat symbol)
  :group 'claude-executor)

(defun claude-executor--find-babel-blocks ()
  "Find all Babel code blocks in the current (possibly narrowed) region.
Returns a list of plists with :lang, :header, :body, :begin, :end."
  (let (blocks)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "^#\\+begin_src\\s-+\\(\\w+\\)\\(.*\\)\n\\(\\(?:.*\n\\)*?\\)#\\+end_src"
              nil t)
        (push (list :lang   (match-string-no-properties 1)
                    :header (match-string-no-properties 2)
                    :body   (match-string-no-properties 3)
                    :begin  (match-beginning 0)
                    :end    (match-end 0))
              blocks)))
    (nreverse blocks)))

(defun claude-executor--lang-extension (lang)
  "File extension for LANG (used for temp file)."
  (cdr (assoc lang '(("python" . ".py")
                     ("sh"     . ".sh")
                     ("bash"   . ".sh")
                     ("elisp"  . ".el")
                     ("R"      . ".R")
                     ("ruby"   . ".rb")
                     ("js"     . ".js")))))

(defun claude-executor--lang-command (lang file)
  "Shell invocation for language LANG with file FILE."
  (cdr (assoc lang
              `(("python" . ,(format "python3 %s" file))
                ("sh"     . ,(format "sh %s" file))
                ("bash"   . ,(format "bash %s" file))
                ("elisp"  . ,(format "emacs --batch --load %s" file))
                ("R"      . ,(format "Rscript %s" file))
                ("ruby"   . ,(format "ruby %s" file))
                ("js"     . ,(format "node %s" file))))))

(defun claude-executor--do-execute (lang body)
  "Write BODY to a temp file, call the matching language CLI,
log in *Assistant Execution Results* and delete the temp file."
  (let* ((ext        (or (claude-executor--lang-extension lang) ""))
         (tmp-file   (make-temp-file "claude-exec-" nil ext))
         (result-buf (get-buffer-create "*Assistant Execution Results*")))
    (with-temp-file tmp-file
      (insert body))
    (with-current-buffer result-buf
      (goto-char (point-max))
      (insert (format "\n=== %s [%s] ===\n" lang
                      (format-time-string "%H:%M:%S")))
      (insert body)
      (insert "\n--- Output ---\n")
      (let ((cmd (claude-executor--lang-command lang tmp-file)))
        (if cmd
            (insert (shell-command-to-string cmd))
          (insert (format "No executor for language: %s\n" lang))))
      (insert "\n"))
    (display-buffer result-buf)
    (delete-file tmp-file)))

(defun claude-executor--file-output-block-p (block)
  "Return non-nil when BLOCK should be executed by Org Babel for file output."
  (let ((lang (plist-get block :lang))
        (header (plist-get block :header)))
    (or (string-match-p "\\_<:file\\_>" header)
        (member lang '("gnuplot" "dot" "plantuml" "mermaid")))))

(defun claude-executor--execute-org-babel-file-block (block)
  "Execute BLOCK with Org Babel and display generated images inline."
  (save-excursion
    (goto-char (plist-get block :begin))
    (let ((org-confirm-babel-evaluate nil))
      (condition-case err
          (progn
            (org-babel-execute-src-block)
            (when (derived-mode-p 'org-mode)
              (org-display-inline-images t t)))
        (error
         (with-current-buffer (get-buffer-create "*Assistant Execution Results*")
           (goto-char (point-max))
           (insert (format "\n=== org-babel file block error [%s] ===\n%s\n"
                           (format-time-string "%H:%M:%S")
                           (error-message-string err)))
           (display-buffer (current-buffer))))))))

(defun claude-executor--execute-babel-block (block)
  "Execute a Babel block.
Checks `claude-executor-allowed-languages' and optionally
`claude-executor-confirm-before-execute'."
  (let ((lang (plist-get block :lang))
        (body (plist-get block :body)))
    (when (member lang claude-executor-allowed-languages)
      (cond
       ((claude-executor--file-output-block-p block)
        (if claude-executor-confirm-before-execute
            (when (yes-or-no-p
                   (format "Execute file-output block (%s)?\n%s\n" lang body))
              (claude-executor--execute-org-babel-file-block block))
          (claude-executor--execute-org-babel-file-block block)))
       (claude-executor-confirm-before-execute
        (when (yes-or-no-p
               (format "Execute block (%s):\n%s\n?" lang body))
          (claude-executor--do-execute lang body)))
       (t
        (claude-executor--do-execute lang body))))))

(defun claude-executor--find-commands ()
  "Find commands in tags of the form '<!-- exec: COMMAND -->'."
  (let (commands)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "<!--\\s-*exec:\\s-*\\(.*?\\)\\s-*-->" nil t)
        (push (match-string-no-properties 1) commands)))
    (nreverse commands)))

(defun claude-executor-run-command (command)
  "Execute COMMAND in the shell.
Output goes to the buffer *Assistant Commands*.
Also callable interactively: M-x or C-c C-x c."
  (interactive "sCommand: ")
  (let ((result-buf (get-buffer-create "*Assistant Commands*")))
    (with-current-buffer result-buf
      (goto-char (point-max))
      (insert (format "\n$ %s\n" command))
      (insert (shell-command-to-string command))
      (insert "\n"))
    (display-buffer result-buf)))

(defun claude-executor--find-autorun-blocks ()
  "Find elisp blocks whose header contains the AUTORUN tag.
Search depends on `claude-executor-elisp-tag'."
  (let (blocks)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (format "^#\\+begin_src elisp.*%s.*\n\\(\\(?:.*\n\\)*?\\)#\\+end_src"
                      claude-executor-elisp-tag)
              nil t)
        (push (match-string-no-properties 1) blocks)))
    (nreverse blocks)))

(defun claude-executor--whitelist-allows-p (code)
  "Check whether CODE (string) only calls functions from
`claude-executor-allowed-functions'.
If no whitelist is set → t (all allowed)."
  (if (null claude-executor-allowed-functions)
      t
    (let ((sexp    (read code))
          (allowed claude-executor-allowed-functions)
          (ok      t))
      (cl-labels ((walk (form)
                    (cond
                     ((and (consp form) (symbolp (car form)))
                      (unless (memq (car form) allowed)
                        (setq ok nil))
                      (mapc #'walk (cdr form)))
                     ((consp form)
                      (mapc #'walk form)))))
        (walk sexp))
      ok)))

(defun claude-executor--safe-eval (code)
  "Evaluate CODE (string) with error handling and logging.
- Whitelist violation → ⚠ entry, no eval.
- Success             → ✓ entry with result.
- Error               → ✗ entry with error message.
Logs go to the buffer *Assistant Actions*."
  (let ((log-buf (get-buffer-create "*Assistant Actions*")))
    (cond
     ((not (claude-executor--whitelist-allows-p code))
      (with-current-buffer log-buf
        (goto-char (point-max))
        (insert (format "\n⚠ [%s]\n  Code: %s\n  Rejected: not in whitelist.\n"
                        (format-time-string "%H:%M:%S") code))
        (display-buffer log-buf)))
     (t
      (condition-case err
          (let ((result (eval (read code))))
            (with-current-buffer log-buf
              (goto-char (point-max))
              (insert (format "\n✓ [%s]\n  Code: %s\n  Result: %s\n"
                              (format-time-string "%H:%M:%S")
                              code result))
              (display-buffer log-buf))
            result)
        (error
         (with-current-buffer log-buf
           (goto-char (point-max))
           (insert (format "\n✗ [%s]\n  Code: %s\n  Error: %s\n"
                           (format-time-string "%H:%M:%S")
                           code err))
           (display-buffer log-buf))))))))

(defun my/gptel--tutorial-plot-response-p ()
  "Return non-nil when the narrowed response looks like plot instructions."
  (save-excursion
    (goto-char (point-min))
    (or (re-search-forward "\\bM-x[[:space:]]+gnuplot\\b" nil t)
        (re-search-forward "\\bgnuplot-send-buffer\\b" nil t)
        (re-search-forward "\\bmake sure you have Gnuplot installed\\b" nil t)
        (and (re-search-forward "^\\s-*[0-9]+\\.\\s-+First\\b" nil t)
             (progn
               (goto-char (point-min))
               (re-search-forward "#\\+begin_src gnuplot\\b" nil t))))))

(defun my/gptel--gnuplot-block-has-file-p ()
  "Return non-nil when the narrowed response has a gnuplot block with :file."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "#\\+begin_src gnuplot\\b.*\\_<:file\\_>" nil t)))

(defun my/gptel-repair-inline-plot-response (beg end)
  "Append executable inline Org when a local model answers plot requests as a tutorial.
This is intentionally narrow: it only repairs obvious gnuplot tutorial answers
that lack a `:file' output block."
  (save-restriction
    (narrow-to-region beg end)
    (when (and (my/gptel--tutorial-plot-response-p)
               (not (my/gptel--gnuplot-block-has-file-p)))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\nCorrect inline Org output:\n\n")
      (insert "$f(x,y)=\\sin(x^2+y^2)$\n\n")
      (insert "#+begin_src gnuplot :file graph3d.png\n")
      (insert "set terminal pngcairo size 1200,900 enhanced font \"Arial,12\"\n")
      (insert "set samples 160\n")
      (insert "set isosamples 160\n")
      (insert "set hidden3d\n")
      (insert "set pm3d at s depthorder\n")
      (insert "set palette rgbformulae 33,13,10\n")
      (insert "set view 58,32\n")
      (insert "set grid\n")
      (insert "set xlabel \"x\"\n")
      (insert "set ylabel \"y\"\n")
      (insert "set zlabel \"f(x,y)\"\n")
      (insert "splot [-4:4][-4:4] sin(x*x+y*y) with pm3d title \"f(x,y)=sin(x^2+y^2)\"\n")
      (insert "#+end_src\n\n")
      (insert "#+RESULTS:\n")
      (insert "[[file:graph3d.png]]\n"))))

(defun claude-executor-response-hook (beg end)
  "Hook for Babel blocks, exec-tags and auto-pattern matching.
Active only when `claude-executor-auto-execute' = t.
Registered in `gptel-post-response-functions'."
  (when claude-executor-auto-execute
    (save-restriction
      (narrow-to-region beg end)
      ;; 0. Repair obvious tutorial-style plot answers from weaker local models.
      (my/gptel-repair-inline-plot-response (point-min) (point-max))
      ;; 1. Babel blocks
      (dolist (block (claude-executor--find-babel-blocks))
        (claude-executor--execute-babel-block block))
      ;; 2. Explicit exec-tags
      (dolist (cmd (claude-executor--find-commands))
        (when (yes-or-no-p (format "Execute command: %s ?" cmd))
          (claude-executor-run-command cmd)))
      ;; 3. User-defined patterns from claude-executor-auto-commands
      (dolist (pattern-cmd claude-executor-auto-commands)
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward (car pattern-cmd) nil t)
            (claude-executor-run-command (cdr pattern-cmd))))))))

(defun claude-executor-autorun-hook (beg end)
  "Hook for AUTORUN elisp blocks.
Always active while `claude-executor-mode' is on.
Respects `claude-executor-confirm-before-execute'."
  (save-restriction
    (narrow-to-region beg end)
    (dolist (code (claude-executor--find-autorun-blocks))
      (if claude-executor-confirm-before-execute
          (when (yes-or-no-p
                 (format "The assistant wants to execute:\n%s\nAllow?" code))
            (claude-executor--safe-eval code))
        (claude-executor--safe-eval code)))))

(defun claude-executor-execute-all-blocks ()
  "Manual variant: execute all Babel blocks in the current buffer."
  (interactive)
  (let ((blocks (claude-executor--find-babel-blocks)))
    (if blocks
        (dolist (block blocks)
          (claude-executor--execute-babel-block block))
      (message "No code blocks found."))))

(defun claude-executor-execute-block-at-point ()
  "Execute the Babel block under the cursor."
  (interactive)
  (let* ((elem (org-element-at-point))
         (lang (org-element-property :language elem))
         (body (org-element-property :value elem)))
    (if (and lang body)
        (claude-executor--do-execute lang body)
      (message "No code block under cursor."))))

(defvar claude-executor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-x e") #'claude-executor-execute-all-blocks)
    (define-key map (kbd "C-c C-x b") #'claude-executor-execute-block-at-point)
    (define-key map (kbd "C-c C-x c") #'claude-executor-run-command)
    map)
  "Keymap for `claude-executor-mode'.")

(define-minor-mode claude-executor-mode
  "Global mode for automatic execution of assistant responses.
Activates the response and AUTORUN hooks on
`gptel-post-response-functions'."
  :lighter " CE"
  :keymap claude-executor-mode-map
  :global t
  (if claude-executor-mode
      (progn
        (add-hook 'gptel-post-response-functions
                  #'claude-executor-response-hook)
        (add-hook 'gptel-post-response-functions
                  #'claude-executor-autorun-hook)
        (message "Response Executor activated."))
    (remove-hook 'gptel-post-response-functions
                 #'claude-executor-response-hook)
    (remove-hook 'gptel-post-response-functions
                 #'claude-executor-autorun-hook)
    (message "Response Executor deactivated.")))

(provide 'claude-executor)

(setq gptel-directives
      (append gptel-directives
              `((assistant . ,(format "You are an Emacs assistant.
When the user wants to perform an action in Emacs, respond with a
#+begin_src elisp :AUTORUN
(your-elisp-code-here)
#+end_src
block. It is executed automatically.
For org-mode TODO in inbox.org:
  (find-file \"%s\")
  (goto-char (point-max))
  (insert \"* TODO Task\")
For arbitrary M-x commands use call-interactively or funcall."
                                      (expand-file-name "data/org/inbox.org" my/data-dir))))))

(let* ((data-d (directory-file-name my/data-dir)))
  (setq gptel-directives
        (append gptel-directives
                `((emacs-local-assistant
                   . ,(replace-regexp-in-string
                       "~/emacs-data" data-d
                       "You are an Emacs assistant running inside Emacs.
Always answer in English.

MOST IMPORTANT:
- If the user asks to check the internet, current rules, latest facts, laws,
  prices, versions, dates, schools, or regulations, DO NOT apologize and DO NOT
  say you cannot access the internet.
- First produce executable web lookup output. If native tool calling works, call
  web_search and then web_fetch_text. If native tool calling does not work, write
  this exact kind of Org block:
#+begin_src elisp :results output
(dolist (r (my/web-search-ddg \"QUERY HERE\" 5))
  (princ (format \"- [[%s][%s]]\\n\" (cdr r) (car r))))
#+end_src
- After search results are visible, fetch official/primary URLs with
  my/web-text or web_fetch_text and cite the URLs in the answer.

CRITICAL RULES:
- If the user asks to plot, draw, graph, render, show inline, or create a math
  function graph, answer with the finished Org content only: LaTeX formula,
  executable source block with :file, and the [[file:...]] result link.
- Never answer plot/graph requests with setup instructions, numbered steps,
  \"make sure you have\", M-x commands, or advice to run gnuplot manually.
- For 3D math plots, always use:
  #+begin_src gnuplot :file graph3d.png
  and include pngcairo, samples, isosamples, splot, #+RESULTS:, and
  [[file:graph3d.png]].
- Never say you cannot create, display, execute, or render code/graphs.
- Never say you cannot browse, search the internet, or access current
  information. Use the web tools or executable Elisp web helpers.
- Never tell the user to press keys, export manually, or run commands manually.
- Produce executable Org-mode blocks when an action, calculation, graph, file,
  shell command, or Emacs operation is requested.
- Use concise responses. Do the requested work directly.

ORG EXECUTION RULES:
- Emacs action: use an elisp block with :AUTORUN.
- Text/code output: use a source block with :results output.
- Graphs/images/diagrams: use a source block with :file.
- Internet/current facts: use web_search first, then web_fetch_text on official
  or primary sources. If native tool calls are unavailable, emit an elisp
  :results output block calling my/web-search-ddg and my/web-text.
- For every :file image block, include the Org result link form immediately after
  the block when the filename is known:
  #+RESULTS:
  [[file:name.png]]
- Org renders image links inline; the post-response hook also calls inline image
  display after executing :file blocks.
- Never write a bare #+begin_src block without :AUTORUN, :results output, or :file.

INLINE MATH AND GRAPHS:
- For any math function, include the formula as LaTeX.
- For any 2D function, include a gnuplot block with :file.
- For any 3D function, include a gnuplot splot block with :file.
- Use detailed plot settings by default: pngcairo terminal, high samples,
  high isosamples for 3D, grid/labels, and a readable palette.
- The graph file should be a PNG with a simple local filename.

Example 3D graph response:
$f(x,y)=\\sin(\\sqrt{x^2+y^2})$

#+begin_src gnuplot :file graph3d.png
set terminal pngcairo size 1200,900 enhanced font \"Arial,12\"
set samples 160
set isosamples 160
set hidden3d
set pm3d at s depthorder
set palette rgbformulae 33,13,10
set view 58,32
set grid
set xlabel \"x\"
set ylabel \"y\"
set zlabel \"f(x,y)\"
splot [-8:8][-8:8] sin(sqrt(x*x+y*y)) with pm3d title \"f(x,y)=sin(sqrt(x^2+y^2))\"
#+end_src

#+RESULTS:
[[file:graph3d.png]]

WEB SEARCH:
- Questions containing \"current\", \"latest\", \"today\", \"check online\",
  \"internet\", laws, school rules, prices, dates, or versions require web
  lookup before answering.
- Prefer official sources, then cite the URLs used.
- Search example when native tool calling is unavailable:
#+begin_src elisp :results output
(dolist (r (my/web-search-ddg \"Abitur private Gymnasium München Bayern aktuelle Regeln\" 5))
  (princ (format \"- [[%s][%s]]\\n\" (cdr r) (car r))))
#+end_src

- Fetch example:
#+begin_src elisp :results output
(princ (my/web-text \"https://www.km.bayern.de/\" 6000))
#+end_src

ORG FILES:
- Org directory: ~/emacs-data/data/org/
- New tasks usually go to inbox.org.
- Do not overwrite config.org, init.el, or config.el.

If the selected backend supports tool calling, prefer tools for multi-step
inspection. If tool calling is unavailable, emit executable Org blocks."
                       t t))))))

(setq gptel-directives
      (append gptel-directives
              '((emacs-planner
                 . "You are the planner for an Emacs agent runtime.
Return only a structured plan. Do not answer conversationally.

Output one or more steps in exactly this format:
- TITLE: short action title
  RATIONALE: why this step is needed
  TOOL: tool_name

For requests whose main goal is user-visible output in the current buffer,
including math, LaTeX, functions, plots, graphs, diagrams, inline images,
explanations, or formatted text, use exactly one step:
- TITLE: Render the requested answer inline
  RATIONALE: The user wants visible Org output, not an autonomous tool plan.
  TOOL: direct_response

For web/current information use TOOL: web_search first.
For file inspection use TOOL: read_file or search_files.
For Emacs automation use TOOL: run_elisp.
Never invent tool names unless no registered tool applies."))))

(let* ((data-d (directory-file-name my/data-dir)))
  (setq gptel-directives
        (append gptel-directives
                `((emacs-assistant
                   . ,(replace-regexp-in-string
                       "~/emacs-data" data-d
                       "You are an Emacs assistant running inside Emacs.
Answer in English. Use tools or executable Org blocks to do requested work.
For plots and diagrams, emit Org Babel blocks with :file and a [[file:...]] result link.
For Emacs actions, use tools or elisp :AUTORUN blocks.
Never tell the user to run manual M-x commands when Emacs can execute the action."
                       t t))))))
;; emacs-assistant globally as default
(setq gptel--system-message
      (alist-get 'emacs-assistant gptel-directives))

;; Also set emacs-assistant for each new gptel session
(add-hook 'gptel-mode-hook
          (lambda ()
            (my/gptel-sync-directive-for-current-runtime)))

;;; --- Security -----------------------------------------------------
;; Confirmation dialog before execution (Babel + AUTORUN)
(setq claude-executor-confirm-before-execute nil)

;; Automatically execute Babel blocks, exec-tags, auto-commands.
;; t = every Babel block with :results output / :file etc. runs directly
;; after an assistant response and produces visible output (or an image).
(setq claude-executor-auto-execute t)

;;; --- Allowed Babel Languages --------------------------------------
(setq claude-executor-allowed-languages
      '("python" "sh" "bash" "elisp" "R" "ruby" "js"
        "gnuplot" "dot" "plantuml" "mermaid"))

;;; --- Pattern-Based Auto Commands (example commented out) ----------
;; (setq claude-executor-auto-commands
;;       '(("pip install \\(.*\\)" . "pip install \\1")))

;;; --- AUTORUN Whitelist (optional) ---------------------------------
;; nil = no restriction. For more security, enter symbols here:
;; (setq claude-executor-allowed-functions
;;       '(find-file find-file-noselect with-current-buffer
;;         goto-char point-max insert save-buffer
;;         org-todo org-insert-heading org-agenda message))

;;; --- Activate Mode ------------------------------------------------
;; Backend + model is set in the "Multi-Backend Configuration" section.
(claude-executor-mode 1)

(defun my/collect-org-todos (&optional limit)
  "Return a list of TODO entries from all org agenda files.
Each entry is a plist with :state :heading :file :deadline :tags."
  (let ((limit (or limit 120))
        results)
    (dolist (file (org-agenda-files))
      (when (file-exists-p file)
        (with-current-buffer (or (find-buffer-visiting file)
                                 (find-file-noselect file t))
          (org-map-entries
           (lambda ()
             (when (< (length results) limit)
               (push (list :state    (org-get-todo-state)
                           :heading  (org-get-heading t t t t)
                           :file     (abbreviate-file-name file)
                           :tags     (mapconcat #'identity (org-get-tags) " ")
                           :deadline (org-entry-get nil "DEADLINE"))
                     results)))
           "/TODO|NEXT|IN-PROGRESS|WAIT|REVIEW" 'agenda))))
    (nreverse results)))

(defun my/build-workspace-context ()
  "Build a compact workspace context string for the gptel system prompt."
  (let* ((todos (my/collect-org-todos 80))
         (by-state (seq-group-by (lambda (e) (plist-get e :state)) todos))
         (format-entries
          (lambda (state entries)
            (when entries
              (concat (format "\n[%s]\n" state)
                      (mapconcat
                       (lambda (e)
                         (let ((dl (plist-get e :deadline))
                               (tags (plist-get e :tags)))
                           (format "  - %s%s%s"
                                   (plist-get e :heading)
                                   (if (and dl (not (string-empty-p dl)))
                                       (format " [due: %s]" dl) "")
                                   (if (and tags (not (string-empty-p tags)))
                                       (format " :%s:" tags) ""))))
                       entries "\n")))))
         (buf (current-buffer))
         (buf-name (buffer-name buf))
         (major (format "%s" major-mode))
         (open-org (seq-filter
                    (lambda (b) (with-current-buffer b
                                  (derived-mode-p 'org-mode)))
                    (buffer-list))))
    (concat
     "=== WORKSPACE CONTEXT ===\n"
     (format "Active buffer: %s  [%s]\n" buf-name major)
     (when open-org
       (format "Open org buffers: %s\n"
               (mapconcat #'buffer-name open-org ", ")))
     "\nTODO summary:\n"
     (mapconcat (lambda (state)
                  (funcall format-entries state (cdr (assoc state by-state))))
                '("NEXT" "IN-PROGRESS" "TODO" "WAIT" "REVIEW") "")
     "\n=== END WORKSPACE CONTEXT ===\n")))

(defvar my/gptel-context--cache nil)
(defvar my/gptel-context--time 0)
(defconst my/gptel-context--ttl 60)

(defun my/workspace-context-string ()
  "Return cached workspace context, refreshing if stale."
  (when (> (- (float-time) my/gptel-context--time)
           my/gptel-context--ttl)
    (setq my/gptel-context--cache (my/build-workspace-context)
          my/gptel-context--time  (float-time)))
  my/gptel-context--cache)

(defun my/gptel-context-invalidate ()
  "Force workspace context to be rebuilt on next gptel call."
  (interactive)
  (setq my/gptel-context--time 0)
  (message "gptel workspace context cache cleared."))

(add-hook 'after-save-hook
          (lambda ()
            (when (derived-mode-p 'org-mode)
              (my/gptel-context-invalidate))))

(defvar my/gptel-context-enabled t
  "When non-nil, inject workspace context into every gptel-send call.")

(defun gptel-agent-runtime-current-buffer-task-text ()
  "Return recent buffer text used for lightweight agent/skill routing."
  (let ((start (max (point-min) (- (point) 4000))))
    (string-trim (buffer-substring-no-properties start (point)))))

(defun my/gptel--inject-context (orig-fn &rest args)
  "Around advice for `gptel-send': route, sync directive, and prepend context."
  (if (not my/gptel-context-enabled)
      (progn
        (my/gptel-sync-directive-for-current-runtime)
        (my/gptel-sync-tools)
        (apply orig-fn args))
    (if gptel-agent-runtime-enable-routing
        (gptel-agent-runtime-apply-route-to-current-buffer
         (gptel-agent-runtime-current-buffer-task-text))
      (my/gptel-sync-directive-for-current-runtime))
    (my/gptel-sync-tools)
    (let* ((ctx   (my/workspace-context-string))
           (orig  gptel--system-message)
           (gptel--system-message (if (and ctx (not (string-empty-p ctx)))
                                      (concat orig "\n\n" ctx)
                                    orig)))
      (apply orig-fn args))))

(advice-add 'gptel-send :around #'my/gptel--inject-context)

(with-eval-after-load 'gptel
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
                (my/collect-org-todos 200) "\n")))

  ;; read_org_file — get raw text of an org file
  (gptel-make-tool
   :name "read_org_file"
   :description "Read the contents of an org file. Path relative to ~ is accepted."
   :args '((:name "path" :type string :description "Org file path, e.g. ~/emacs-data/data/org/todo.org — use your actual data dir"))
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
                 (if (my/gptel-protected-p p)
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
                                  (if (my/gptel-protected-p (expand-file-name file))
                                      (error "write-file blocked by run_elisp: %s is protected" file)
                                    (apply orig-write-file file args))))
                               ((symbol-function 'set-visited-file-name)
                                (lambda (file &rest args)
                                  (if (and file (not (string-empty-p file))
                                           (my/gptel-protected-p (expand-file-name file)))
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
                 (if (my/gptel-protected-p p)
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
                   (let ((results (my/web-search-ddg query (or limit 5))))
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
                   (my/web-text url (or max-chars 6000))
                 (error (format "Error: %s" err)))))

  ;; web_extract_images — list image URLs from a page
  (gptel-make-tool
   :name "web_extract_images"
   :description "Extract image URLs from a web page."
   :args '((:name "url" :type string :description "URL to inspect")
           (:name "limit" :type integer :description "Maximum number of images, default 10"))
   :function (lambda (url limit)
               (condition-case err
                   (let ((images (my/web-extract-images url (or limit 10))))
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
                   (my/web-fetch-image
                    url
                    (when (and directory (not (string-empty-p directory)))
                      (expand-file-name directory)))
                 (error (format "Error: %s" err))))))

(with-eval-after-load 'gptel
  ;; Set globally — all tools are registered by this point since this section
  ;; is the last with-eval-after-load 'gptel block in config.el.
  (setq gptel-use-tools t)
  (setq gptel-tools (my/gptel-tools-all)))

(defvar gptel-agent-runtime--current-session nil
  "The active agent session object.")

(defvar gptel-agent-runtime--origin-buffer nil
  "Buffer where the current agent session should render user-visible output.")

(defun gptel-agent-runtime-start (goal &optional role)
  "Start an autonomous agent session for GOAL with optional ROLE.
The loop is: observe -> plan -> delegate -> act -> observe -> reflect ->
remember -> continue."
  (interactive "sAgent goal: ")
  (let* ((task (gptel-agent-runtime-create-task "Main Task" goal))
         (session (gptel-agent-runtime-create-session
                   task (or role gptel-agent-runtime-default-role))))
    (setq gptel-agent-runtime--current-session session)
    (setq gptel-agent-runtime--origin-buffer (current-buffer))
    (setf (gptel-agent-runtime-task-status task) 'running)
    (push (format "%s session started for: %s"
                  (gptel-agent-runtime--timestamp) goal)
          (gptel-agent-runtime-session-decisions session))
    (message "Agent session started: %s" (gptel-agent-runtime-session-id session))
    (gptel-agent-runtime--continue session)))

(defun gptel-agent-runtime-stop ()
  "Stop the current autonomous agent session."
  (interactive)
  (when gptel-agent-runtime--current-session
    (setf (gptel-agent-runtime-task-status
           (gptel-agent-runtime-session-root-task
            gptel-agent-runtime--current-session))
          'cancelled)
    (gptel-agent-runtime-memory-write-session
     gptel-agent-runtime--current-session)
    (message "Agent session stopped: %s"
             (gptel-agent-runtime-session-id
              gptel-agent-runtime--current-session))))

(defun gptel-agent-runtime-session-summary (&optional session)
  "Return a short status summary for SESSION or the active session."
  (let* ((session (or session gptel-agent-runtime--current-session))
         (task (and session (gptel-agent-runtime-session-root-task session)))
         (plan (and task (gptel-agent-runtime-task-notes task))))
    (if (not session)
        "No active gptel-agent-runtime session."
      (format "Session: %s\nGoal: %s\nStatus: %s\nIteration: %s/%s\nPlan steps: %s\nObservations: %s"
              (gptel-agent-runtime-session-id session)
              (gptel-agent-runtime-task-goal task)
              (gptel-agent-runtime-task-status task)
              (gptel-agent-runtime-session-iteration session)
              gptel-agent-runtime-max-iterations
              (if (gptel-agent-runtime-plan-p plan)
                  (length (gptel-agent-runtime-plan-steps plan))
                0)
              (length (gptel-agent-runtime-session-observations session))))))

(defun gptel-agent-runtime-describe-session ()
  "Display a summary of the current autonomous agent session."
  (interactive)
  (message "%s" (gptel-agent-runtime-session-summary)))

(defun gptel-agent-runtime--continue (session)
  "Continue SESSION through the next loop phase."
  (cond
   ((not (eq session gptel-agent-runtime--current-session))
    (message "Ignoring stale agent callback."))
   ((>= (gptel-agent-runtime-session-iteration session)
        gptel-agent-runtime-max-iterations)
    (gptel-agent-runtime--finalize-task
     (gptel-agent-runtime-session-root-task session)
     session
     'max-iterations))
   (t
    (setf (gptel-agent-runtime-session-iteration session)
          (1+ (gptel-agent-runtime-session-iteration session)))
    (setf (gptel-agent-runtime-session-updated-at session)
          (gptel-agent-runtime--timestamp))
    (let* ((task (gptel-agent-runtime-session-current-task session))
           (plan (gptel-agent-runtime-task-notes task)))
      (if (and (gptel-agent-runtime-plan-p plan)
               (gptel-agent-runtime-next-plan-step plan))
          (gptel-agent-runtime--act session)
        (gptel-agent-runtime--observe-and-plan session))))))

(defun gptel-agent-runtime--workspace-observation ()
  "Return a compact observation string for the current workspace."
  (string-trim
   (concat
    (format "Current buffer: %s\n" (buffer-name))
    (when (fboundp 'my/workspace-context-string)
      (format "Workspace context:\n%s\n" (my/workspace-context-string)))
    (when gptel-agent-runtime-last-route
      (format "Last route: %s\n" (plist-get gptel-agent-runtime-last-route :reason))))))

(defun gptel-agent-runtime--tool-names ()
  "Return currently available gptel tool names."
  (mapcar (lambda (tool)
            (if (fboundp 'gptel-tool-name)
                (gptel-tool-name tool)
              (plist-get tool :name)))
          (or (my/gptel-tools-all) nil)))

(defun gptel-agent-runtime--planner-system ()
  "Return the strict system prompt for planner JSON."
  (concat
   "You are the planner in an Emacs-native autonomous agent loop.\n"
   "Return only JSON. No markdown, no prose.\n"
   "Schema:\n"
   "{\"steps\":[{\"title\":\"short action\",\"rationale\":\"why needed\","
   "\"agent\":\"assistant|planner|executor|reviewer|memory-curator\","
   "\"tool\":\"direct_response or an available tool name\","
   "\"args\":{},\"risk\":\"safe|read|write|shell|destructive\"}]}\n"
   "Prefer a few concrete steps. Use direct_response only for user-visible output. "
   "For current/latest/internet facts, use web_search before answering. "
   "For file edits, inspect before writing."))

(defun gptel-agent-runtime--observe-and-plan (session)
  "Observe current state and ask the planner to create a JSON plan for SESSION."
  (let* ((task (gptel-agent-runtime-session-current-task session))
         (goal (gptel-agent-runtime-task-goal task))
         (route (gptel-agent-runtime-route-task goal))
         (observation (gptel-agent-runtime--workspace-observation))
         (prompt (format
                  "GOAL:\n%s\n\nROUTE:\n%s\n\nAVAILABLE TOOLS:\n%s\n\nOBSERVATIONS:\n%s\n\nCreate the next executable plan."
                  goal
                  (gptel-agent-runtime-route-summary goal)
                  (mapconcat #'identity (gptel-agent-runtime--tool-names) ", ")
                  observation)))
    (push observation (gptel-agent-runtime-session-observations session))
    (push (format "%s planning route: %s"
                  (gptel-agent-runtime--timestamp)
                  (plist-get route :reason))
          (gptel-agent-runtime-session-decisions session))
    (message "Agent [%s] planning..." (gptel-agent-runtime-session-id session))
    (gptel-request
     prompt
     :system (gptel-agent-runtime--planner-system)
     :callback
     (lambda (response _info)
       (if (not response)
           (gptel-agent-runtime--handle-execution-error
            nil "Planner returned no response." session)
         (gptel-agent-runtime--handle-plan-response response session))))))

(defun gptel-agent-runtime--extract-json (text)
  "Extract the first likely JSON object from TEXT."
  (when (stringp text)
    (let* ((start (string-match "{" text))
           (end (and start (cl-position ?} text :from-end t))))
      (when (and start end)
        (substring text start (1+ end))))))

(defun gptel-agent-runtime--json-read-plist (text)
  "Read TEXT as JSON and return plists/lists."
  (let ((json-object-type 'plist)
        (json-array-type 'list)
        (json-key-type 'keyword))
    (json-read-from-string text)))

(defun gptel-agent-runtime--keywordize-risk (risk)
  "Normalize RISK from JSON to a risk symbol."
  (let ((risk (intern (or (and (stringp risk) risk)
                          (and (symbolp risk) (symbol-name risk))
                          "safe"))))
    (if (assoc risk gptel-agent-runtime--risk-order) risk 'safe)))

(defun gptel-agent-runtime--normalize-args (args)
  "Normalize JSON ARGS into a keyword plist."
  (cond
   ((null args) nil)
   ((and (listp args) (keywordp (car args))) args)
   ((hash-table-p args)
    (let (plist)
      (maphash (lambda (key value)
                 (setq plist
                       (plist-put plist
                                  (intern (format ":%s" key))
                                  value)))
               args)
      plist))
   (t nil)))

(defun gptel-agent-runtime--parse-plan (text)
  "Parse planner TEXT into plan steps.
The preferred format is JSON with a top-level :steps list. A single
`direct_response' step is returned if parsing fails."
  (condition-case err
      (let* ((json (gptel-agent-runtime--extract-json text))
             (data (and json (gptel-agent-runtime--json-read-plist json)))
             (items (plist-get data :steps)))
        (if (not items)
            (error "JSON did not contain :steps")
          (cl-loop
           for item in items
           for title = (or (plist-get item :title) "Untitled step")
           for rationale = (or (plist-get item :rationale) "")
           for tool = (or (plist-get item :tool) "direct_response")
           for risk = (gptel-agent-runtime--keywordize-risk
                       (plist-get item :risk))
           for agent = (or (plist-get item :agent) "assistant")
           for route = (gptel-agent-runtime-route-task
                        (format "%s %s %s" title rationale tool))
           collect
           (apply #'gptel-agent-runtime-create-plan-step
                  title rationale tool risk
                  (list :agent agent
                        :skills (mapcar #'gptel-agent-runtime-skill-name
                                         (plist-get route :skills))
                        :args (gptel-agent-runtime--normalize-args
                               (plist-get item :args)))))))
    (error
     (list
      (gptel-agent-runtime-create-plan-step
       "Answer directly"
       (format "Planner output could not be parsed as JSON: %s" err)
       "direct_response" 'safe
       :agent "assistant"
       :args nil)))))

(defun gptel-agent-runtime--handle-plan-response (response session)
  "Parse planner RESPONSE into SESSION plan and move to action."
  (let* ((steps (gptel-agent-runtime--parse-plan response))
         (task (gptel-agent-runtime-session-current-task session))
         (plan (gptel-agent-runtime-create-plan task steps)))
    (setf (gptel-agent-runtime-plan-status plan) 'active)
    (setf (gptel-agent-runtime-task-notes task) plan)
    (push (format "%s plan created with %d step(s)."
                  (gptel-agent-runtime--timestamp) (length steps))
          (gptel-agent-runtime-session-decisions session))
    (message "Plan ready (%d step%s)."
             (length steps) (if (= (length steps) 1) "" "s"))
    (gptel-agent-runtime--act session)))

(defun gptel-agent-runtime--act (session)
  "Delegate and execute the next step in SESSION."
  (let* ((task (gptel-agent-runtime-session-current-task session))
         (plan (gptel-agent-runtime-task-notes task))
         (step (gptel-agent-runtime-next-plan-step plan)))
    (if (not step)
        (gptel-agent-runtime--finalize-task task session 'done)
      (setf (gptel-agent-runtime-plan-step-status step) 'running)
      (setf (gptel-agent-runtime-plan-step-attempts step)
            (1+ (or (gptel-agent-runtime-plan-step-attempts step) 0)))
      (push (format "%s delegated '%s' to %s using %s."
                    (gptel-agent-runtime--timestamp)
                    (gptel-agent-runtime-plan-step-title step)
                    (or (gptel-agent-runtime-plan-step-agent step) "assistant")
                    (or (gptel-agent-runtime-plan-step-suggested-tool step)
                        "direct_response"))
            (gptel-agent-runtime-session-decisions session))
      (message "Agent [%s] %s -> %s"
               (gptel-agent-runtime-session-id session)
               (or (gptel-agent-runtime-plan-step-agent step) "assistant")
               (gptel-agent-runtime-plan-step-title step))
      (gptel-agent-runtime--dispatch-action step session))))

(defun gptel-agent-runtime--find-native-tool (name)
  "Return gptel tool named NAME, or nil."
  (cl-find name (my/gptel-tools-all)
           :key (lambda (tool)
                  (if (fboundp 'gptel-tool-name)
                      (gptel-tool-name tool)
                    (plist-get tool :name)))
           :test #'equal))

(defun gptel-agent-runtime--confirm-action-p (step)
  "Return non-nil when STEP may execute."
  (let ((risk (or (gptel-agent-runtime-plan-step-risk step) 'safe)))
    (or (and gptel-agent-runtime-auto-execute-safe-actions
             (not (gptel-agent-runtime-risk-at-least-p risk 'write)))
        (not (gptel-agent-runtime-confirmation-required-p risk))
        (and (not noninteractive)
             (yes-or-no-p
              (format "Agent wants to run %s (%s risk): %s. Continue? "
                      (gptel-agent-runtime-plan-step-suggested-tool step)
                      risk
                      (gptel-agent-runtime-plan-step-title step)))))))

(defun gptel-agent-runtime--dispatch-action (step session)
  "Execute STEP for SESSION and continue to reflection."
  (let ((tool-name (or (gptel-agent-runtime-plan-step-suggested-tool step)
                       "direct_response")))
    (condition-case err
        (cond
         ((not (gptel-agent-runtime--confirm-action-p step))
          (gptel-agent-runtime--observe-result
           step session
           (gptel-agent-runtime-result-error
            :tool tool-name
            :error "Action was not confirmed.")))
         ((equal tool-name "direct_response")
          (gptel-agent-runtime--direct-response step session))
         ((equal tool-name "remember")
          (gptel-agent-runtime--observe-result
           step session
           (gptel-agent-runtime-result-ok
            :tool tool-name
            :output (gptel-agent-runtime-memory-write-session session))))
         (t
          (let ((tool (gptel-agent-runtime--find-native-tool tool-name)))
            (if tool
                (gptel-agent-runtime--call-native-tool tool step session)
              (gptel-agent-runtime--observe-result
               step session
               (gptel-agent-runtime-result-error
                :tool tool-name
                :error (format "Unknown tool: %s" tool-name)))))))
      (error
       (gptel-agent-runtime--handle-execution-error step err session)))))

(defun gptel-agent-runtime--direct-response (step session)
  "Ask the delegated agent to produce user-visible output for STEP."
  (let* ((task (gptel-agent-runtime-session-current-task session))
         (goal (gptel-agent-runtime-task-goal task))
         (agent (gptel-agent-runtime-find-agent
                 (or (gptel-agent-runtime-plan-step-agent step) "assistant")))
         (directive (gptel-agent-runtime-agent-directive agent))
         (base-system (or (alist-get directive gptel-directives)
                          (alist-get (my/gptel-directive-for-current-runtime)
                                     gptel-directives)
                          "You are an Emacs assistant."))
         (skill-text (gptel-agent-runtime-skill-instructions
                      (cl-remove nil
                                 (mapcar #'gptel-agent-runtime-find-skill
                                         (or (gptel-agent-runtime-plan-step-skills step)
                                             nil)))))
         (system (if skill-text
                     (concat base-system "\n\n" skill-text)
                   base-system)))
    (message "Agent [%s] rendering via %s..."
             (gptel-agent-runtime-session-id session) directive)
    (gptel-request
     (format "GOAL:\n%s\n\nSTEP:\n%s\n\nRATIONALE:\n%s\n\nProduce the requested user-visible result now."
             goal
             (gptel-agent-runtime-plan-step-title step)
             (gptel-agent-runtime-plan-step-rationale step))
     :system system
     :callback
     (lambda (response _info)
       (if (not response)
           (gptel-agent-runtime--observe-result
            step session
            (gptel-agent-runtime-result-error
             :tool "direct_response"
             :error "Direct response returned no output."))
         (let ((buffer (or (and (buffer-live-p gptel-agent-runtime--origin-buffer)
                                gptel-agent-runtime--origin-buffer)
                           (current-buffer))))
           (with-current-buffer buffer
             (let ((beg (point-max)))
               (goto-char beg)
               (unless (bolp) (insert "\n"))
               (insert response "\n")
               (run-hook-with-args 'gptel-post-response-functions beg (point)))))
         (gptel-agent-runtime--observe-result
          step session
          (gptel-agent-runtime-result-ok
           :tool "direct_response"
           :output response)))))))

(defun gptel-agent-runtime--call-native-tool (tool step session)
  "Execute native gptel TOOL for STEP in SESSION."
  (if (and (fboundp 'gptel-tool-async) (gptel-tool-async tool))
      (gptel-agent-runtime--observe-result
       step session
       (gptel-agent-runtime-result-error
        :tool (gptel-tool-name tool)
        :error "Async gptel tools are not supported by this loop yet."))
    (let* ((args (gptel-agent-runtime--normalize-args
                  (gptel-agent-runtime-plan-step-args step)))
           (arg-values (if (fboundp 'gptel--map-tool-args)
                           (gptel--map-tool-args tool args)
                         nil))
           (result (apply (gptel-tool-function tool) arg-values)))
      (gptel-agent-runtime--observe-result
       step session
       (gptel-agent-runtime-result-ok
        :tool (gptel-tool-name tool)
        :output (format "%s" result))))))

(defun gptel-agent-runtime--observe-result (step session result)
  "Record RESULT for STEP, then ask the reviewer to reflect."
  (let ((observation
         (format "%s step '%s' via %s -> %s\n%s%s"
                 (gptel-agent-runtime--timestamp)
                 (gptel-agent-runtime-plan-step-title step)
                 (gptel-agent-runtime-action-result-tool result)
                 (gptel-agent-runtime-action-result-status result)
                 (or (gptel-agent-runtime-action-result-output result) "")
                 (if (gptel-agent-runtime-action-result-error result)
                     (format "\nERROR: %s"
                             (gptel-agent-runtime-action-result-error result))
                   ""))))
    (setf (gptel-agent-runtime-plan-step-result step) result)
    (push observation (gptel-agent-runtime-plan-step-observations step))
    (push observation (gptel-agent-runtime-session-observations session))
    (push result (gptel-agent-runtime-session-tool-results session))
    (gptel-agent-runtime--reflect step result session)))

(defun gptel-agent-runtime--reflection-system ()
  "Return the strict system prompt for reflection JSON."
  (concat
   "You are the reviewer in an Emacs autonomous agent loop.\n"
   "Return only JSON. No markdown, no prose.\n"
   "Schema: {\"status\":\"continue|replan|done|failed\","
   "\"reflection\":\"short assessment\","
   "\"memory\":\"short reusable lesson or empty string\"}\n"
   "Use continue when the step succeeded and more plan steps remain. "
   "Use replan when the tool failed or more information is needed. "
   "Use done only when the overall goal is satisfied."))

(defun gptel-agent-runtime--reflect (step result session)
  "Reflect on RESULT of STEP in SESSION and decide how to continue."
  (let* ((task (gptel-agent-runtime-session-current-task session))
         (plan (gptel-agent-runtime-task-notes task))
         (prompt (format
                  "GOAL:\n%s\n\nPLAN STATUS:\n%s\n\nSTEP:\n%s\n\nRESULT STATUS: %s\nOUTPUT:\n%s\nERROR:\n%s\n\nDecide the next loop state."
                  (gptel-agent-runtime-task-goal task)
                  (mapconcat
                   (lambda (s)
                     (format "- [%s] %s"
                             (gptel-agent-runtime-plan-step-status s)
                             (gptel-agent-runtime-plan-step-title s)))
                   (gptel-agent-runtime-plan-steps plan)
                   "\n")
                  (gptel-agent-runtime-plan-step-title step)
                  (gptel-agent-runtime-action-result-status result)
                  (or (gptel-agent-runtime-action-result-output result) "")
                  (or (gptel-agent-runtime-action-result-error result) ""))))
    (message "Agent [%s] reflecting..." (gptel-agent-runtime-session-id session))
    (gptel-request
     prompt
     :system (gptel-agent-runtime--reflection-system)
     :callback
     (lambda (response _info)
       (gptel-agent-runtime--handle-reflection-response
        response step result session)))))

(defun gptel-agent-runtime--parse-reflection (response)
  "Parse reflection RESPONSE into a plist."
  (condition-case nil
      (let* ((json (gptel-agent-runtime--extract-json response))
             (data (and json (gptel-agent-runtime--json-read-plist json))))
        (list :status (intern (or (plist-get data :status) "continue"))
              :reflection (or (plist-get data :reflection) "")
              :memory (or (plist-get data :memory) "")))
    (error
     (list :status 'continue
           :reflection (or response "Reflection could not be parsed.")
           :memory ""))))

(defun gptel-agent-runtime--handle-reflection-response
    (response step result session)
  "Apply reviewer RESPONSE for STEP and RESULT in SESSION."
  (let* ((reflection (gptel-agent-runtime--parse-reflection response))
         (status (plist-get reflection :status))
         (memory (plist-get reflection :memory))
         (task (gptel-agent-runtime-session-current-task session)))
    (push (plist-get reflection :reflection)
          (gptel-agent-runtime-plan-step-reflections step))
    (push (format "%s reflection for '%s': %s"
                  (gptel-agent-runtime--timestamp)
                  (gptel-agent-runtime-plan-step-title step)
                  (plist-get reflection :reflection))
          (gptel-agent-runtime-session-decisions session))
    (when (and memory (not (string-empty-p (string-trim memory))))
      (push (format "%s MEMORY: %s"
                    (gptel-agent-runtime--timestamp)
                    (string-trim memory))
            (gptel-agent-runtime-session-decisions session)))
    (pcase status
      ('done
       (setf (gptel-agent-runtime-plan-step-status step) 'done)
       (gptel-agent-runtime--finalize-task task session 'done))
      ('failed
       (setf (gptel-agent-runtime-plan-step-status step) 'failed)
       (gptel-agent-runtime--finalize-task task session 'failed))
      ('replan
       (setf (gptel-agent-runtime-plan-step-status step) 'failed)
       (setf (gptel-agent-runtime-task-notes task) nil)
       (gptel-agent-runtime--continue session))
      (_
       (setf (gptel-agent-runtime-plan-step-status step)
             (if (eq (gptel-agent-runtime-action-result-status result) 'ok)
                 'done
               'failed))
       (gptel-agent-runtime-memory-write-session session)
       (if (gptel-agent-runtime-next-plan-step
            (gptel-agent-runtime-task-notes task))
           (gptel-agent-runtime--continue session)
         (gptel-agent-runtime--finalize-task task session 'done))))))

(defun gptel-agent-runtime--finalize-task (task session reason)
  "Finalize TASK in SESSION with REASON and write memory."
  (setf (gptel-agent-runtime-task-status task)
        (if (eq reason 'done) 'completed reason))
  (setf (gptel-agent-runtime-session-updated-at session)
        (gptel-agent-runtime--timestamp))
  (let ((path (gptel-agent-runtime-memory-write-session session)))
    (message "Agent session %s finished (%s). Memory: %s"
             (gptel-agent-runtime-session-id session)
             reason
             path)))

(defun gptel-agent-runtime--handle-execution-error (step err session)
  "Record ERR for STEP in SESSION and continue through reflection."
  (let ((err-msg (if (stringp err) err (error-message-string err))))
    (if step
        (gptel-agent-runtime--observe-result
         step session
         (gptel-agent-runtime-result-error
          :tool (gptel-agent-runtime-plan-step-suggested-tool step)
          :error err-msg))
      (progn
        (push (format "%s ERROR: %s"
                      (gptel-agent-runtime--timestamp)
                      err-msg)
              (gptel-agent-runtime-session-observations session))
        (gptel-agent-runtime-memory-write-session session)
        (message "Agent error: %s" err-msg)))))

;; Select the local model only after directives, tools, and compatibility
;; helpers have been defined. In the old literate config this ordering was
;; implicit; as a package it must be explicit.
(when (and (boundp 'my/gptel-ollama-backend)
           my/gptel-ollama-backend)
  (gptel-agent-runtime-use-default-local-model))

(provide 'gptel-agent-runtime)

;;; gptel-agent-runtime.el ends here
