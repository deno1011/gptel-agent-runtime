;;; gar-core.el --- package metadata, defcustoms, defvars, structs, base helpers -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Extracted from the monolith
;; gptel-agent-runtime.org on 2026-05-27 as PR 11 of the module split.

;;; Commentary:

;; The lowest layer of the runtime, loaded first by the master. Owns
;; the package's defgroup, the ~50 defcustoms, all defvars not yet
;; owned by other modules, all cl-defstruct definitions, and the
;; low-level helper functions every other module depends on.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

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

(defconst gptel-agent-runtime-state-schema-version 1
  "Current schema version for persisted runtime state files.
Files written by the runtime get a leading header recording this version so
that future schema changes can be detected and migrated without silently
loading incompatible data.")

(defcustom gptel-agent-runtime-enabled nil
  "When non-nil, enable the experimental agent runtime layer.
This switch is reserved for the future planner/executor loop. Existing gptel
chat, tools, and Response Executor behavior do not depend on it yet."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-chat-router-enabled t
  "When non-nil, enabled runtimes may route normal gptel sends to swarm mode.
This option is gated by `gptel-agent-runtime-enabled'. When that master switch
is nil, normal gptel chat behavior is unchanged."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-chat-router-mode 'auto
  "How normal gptel chat should enter autonomous/swarm mode.
`auto' starts a runtime session for prompts classified as complex.
`ask' asks before starting the runtime session.
`off' never starts a runtime session from normal gptel chat."
  :type '(choice (const :tag "Auto-start suitable tasks" auto)
                 (const :tag "Ask before starting" ask)
                 (const :tag "Off" off))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-chat-router-startup-mode 'off
  "Startup mode for normal gptel chat routing.
`off' keeps normal gptel sends as direct chat unless routing is enabled
interactively.
`ask' enables the runtime and asks before complex prompts enter swarm mode.
`auto' enables the runtime and starts swarm sessions for prompts classified as
complex.

This setting is applied when the package loads and can be changed with
`gptel-agent-runtime-set-chat-router-startup-mode'."
  :type '(choice (const :tag "Off" off)
                 (const :tag "Ask before starting" ask)
                 (const :tag "Auto-start suitable tasks" auto))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-chat-router-min-score 3
  "Minimum heuristic score needed to route a gptel prompt into swarm mode."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-max-iterations 8
  "Maximum number of observe/plan/act iterations in one agent run.
The limit prevents runaway loops once the planner/executor loop is added."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-require-confirmation-for-risky-actions nil
  "When non-nil, require confirmation before risky tool actions.
The package default is open so local testing, raw-tool shims, and maximum
functionality are not blocked by interactive prompts. Set this to non-nil in a
personal or site config when you want confirmation for write, shell, or
destructive actions."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-auto-execute-safe-actions t
  "When non-nil, auto-execute safe/read actions in autonomous runs.
Write, shell, and destructive actions still honor
`gptel-agent-runtime-require-confirmation-for-risky-actions'."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-event-log-enabled t
  "When non-nil, record runtime events to memory and an append-only file."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-event-log-file
  (expand-file-name "events.el" (expand-file-name "gptel-agent-runtime/" user-emacs-directory))
  "Append-only event log file used by the event bus scaffold."
  :type 'file
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-event-log-max-memory 300
  "Maximum number of recent events kept in memory."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-event-log-ignore-write-errors t
  "When non-nil, keep running if the append-only event log cannot be written.
This prevents parallel batch tests or multiple Emacs processes from failing the
agent runtime because of transient file locks or filesystem write errors. The
in-memory event log and live swarm buffer still receive the event."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-idle-pump-enabled nil
  "When non-nil, run a background idle pump that advances the runtime clock.
The pump fires on an idle timer every `gptel-agent-runtime-idle-pump-interval'
seconds and advances the OpenClaw substrate tick so background subscribers
(memory consolidation, novelty rescoring, candidate playbook synthesis) can do
work even when no user request is in flight. Default is off so a fresh package
load does not start a background timer until the user opts in."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-idle-pump-interval 30
  "Idle seconds between background pump ticks when the idle pump is enabled."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-policy-enabled t
  "When non-nil, route tool execution through the configurable policy broker."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-wrap-untrusted-context t
  "When non-nil, wrap tool/web/file observations before reusing them in prompts.
The wrapper marks observations as evidence only and tells agents not to obey
instructions that appear inside untrusted data."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-untrusted-context-max-chars 12000
  "Maximum characters retained from one untrusted context block."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-tool-policy nil
  "Fine-grained policy alist for runtime tools.
Each entry is (TOOL . PLIST), where TOOL is a string or symbol. Supported PLIST
keys include:

  :default allow|deny
  :confirm nil|always|write|shell|destructive
  :paths (directories or files allowed for path-like arguments)
  :agents (agent names allowed to use the tool)
  :blocked-patterns (regexps checked against command/code arguments)
  :taint trusted|untrusted

This supplements the built-in safety checks. It does not weaken protected-path
or blocked-command checks unless the user explicitly customizes those lower
level lists."
  :type 'alist
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-policy-preset 'open
  "Named safety-policy preset last applied by the runtime.
`open' keeps maximum local functionality for testing.
`balanced' asks before code, Elisp, writes, exports, and Org mutations.
`strict' denies code/Elisp execution and asks before writes/exports/mutations.
`research-only' allows read/search/web research and denies mutation/code tools.
`coding-only' allows coding tools with confirmation and denies web/image fetches."
  :type '(choice (const :tag "Open testing" open)
                 (const :tag "Balanced daily use" balanced)
                 (const :tag "Strict" strict)
                 (const :tag "Research only" research-only)
                 (const :tag "Coding only" coding-only))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-default-tool-policy
  '(("execute_code" . (:taint untrusted))
    ("run_elisp" . (:taint untrusted))
    ("org_export" . (:taint trusted))
    ("write_file" . (:taint trusted))
    ("write_org_file" . (:taint trusted))
    ("add_todo" . (:taint trusted))
    ("change_todo_state" . (:taint trusted))
    ("set_deadline" . (:taint trusted))
    ("add_tag" . (:taint trusted))
    ("web_search" . (:taint untrusted))
    ("web_fetch_text" . (:taint untrusted))
    ("web_extract_images" . (:taint untrusted))
    ("web_fetch_image" . (:taint untrusted))
    ("read_file" . (:taint untrusted))
    ("read_org_file" . (:taint untrusted))
    ("get_buffer_content" . (:taint untrusted)))
  "Open built-in default policies for runtime tools.
Entries use the same format as `gptel-agent-runtime-tool-policy'. User policies
in `gptel-agent-runtime-tool-policy' override these defaults per tool.

These defaults intentionally avoid extra :confirm or :default deny rules so
tests and local experimentation keep maximum functionality. They mainly mark
external/tool-derived data as trusted or untrusted evidence. Hardened setups
should add confirmation, path, agent, or deny rules in
`gptel-agent-runtime-tool-policy'."
  :type 'alist
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-data-directory
  user-emacs-directory
  "Root directory for runtime data the package may consult for context.
Hosts that already define `my/data-dir' before requiring this package will
have its value copied into this defcustom at the tail of the master load
sequence. New setups should customise this defcustom directly. The package
does not write here -- that is `gptel-agent-runtime-memory-directory'."
  :type 'directory
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-memory-directory
  (expand-file-name "gptel-agent-runtime/" user-emacs-directory)
  "Directory for future persistent agent memory and session state."
  :type 'directory
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-memory-retrieval-limit 5
  "Maximum number of prior memory snippets injected into planning."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-enable-organization-routing t
  "When non-nil, route tasks through organization units before agent selection.
Organization units are lightweight departments such as research, engineering,
review, and memory. They make swarm-style routing inspectable without requiring
separate processes for every role."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-enable-playbook-learning t
  "When non-nil, successful autonomous sessions create reusable playbooks.
Playbooks are local strategy memories that can be matched during future
planning so similar tasks need fewer reasoning iterations."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-playbook-match-limit 3
  "Maximum number of matching playbooks injected into a planner prompt."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-default-process 'hierarchical
  "Default organizational process for autonomous sessions.
`hierarchical' uses manager-style planning, delegation, execution, review, and
memory. `delphi' asks isolated specialist agents for drafts, then aggregates.
`direct' keeps the earlier lightweight planner/executor behavior.
`brainstorm' runs inventor + simplifier + skeptic + planner for novel tasks.
`hypothesis-test' runs a single cheap experiment step and feeds its observed
result back as evidence.
`peer-review' adds skeptic + risk-officer review before any write/code-exec
step is allowed to run."
  :type '(choice (const :tag "Hierarchical chief clerk" hierarchical)
                 (const :tag "Delphi peer review" delphi)
                 (const :tag "Direct planner/executor" direct)
                 (const :tag "Brainstorm for novel tasks" brainstorm)
                 (const :tag "Hypothesis-test experiment" hypothesis-test)
                 (const :tag "Peer-review before mutations" peer-review))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-enable-plan-review t
  "When non-nil, run an Advocatus Diaboli review before executing complex plans."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-plan-review-risk-threshold 'write
  "Risk level at or above which plans require pre-execution review."
  :type '(choice (const safe)
                 (const read)
                 (const write)
                 (const shell)
                 (const destructive))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-delphi-agents
  '("planner" "executor" "reviewer")
  "Agent names used for the Delphi process scaffold."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-memory-retrieval-method 'lexical
  "Memory retrieval method.
`lexical' uses local keyword scoring. `ollama-embeddings' asks Ollama for
embeddings and falls back to lexical scoring when unavailable."
  :type '(choice (const :tag "Lexical" lexical)
                 (const :tag "Ollama embeddings" ollama-embeddings))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-embedding-model "nomic-embed-text"
  "Ollama embedding model used when memory retrieval method is `ollama-embeddings'."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-embedding-cache-enabled t
  "When non-nil, persist Ollama embeddings in a local cache file."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-enable-parallel-workers t
  "When non-nil, allow independent worker requests for parallelizable steps.
Parallel workers are separate gptel requests with their own agent directive and
worker state. Tool mutation remains guarded by safety policy."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-max-parallel-workers 3
  "Maximum number of worker requests launched from one plan at a time."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-worker-max-retries 1
  "Maximum automatic retries for a failed parallel worker.
Retries are used for worker-level execution failures such as missing tools,
exceptions, or empty direct-response callbacks. Verification failures still flow
through the normal reviewer/reflection loop."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-parallel-safe-tool-names
  '("direct_response"
    "read_file" "read_org_file" "list_directory" "search_files"
    "list_buffers" "get_buffer_content" "get_org_structure" "get_todos"
    "web_search" "web_fetch_text" "web_extract_images")
  "Tool names that may run as safe/read parallel workers."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-raw-tool-call-names
  '("list_buffers" "get_buffer_content" "get_current_buffer_info"
    "read_file" "read_org_file" "list_directory" "search_files"
    "get_org_structure" "get_todos"
    "web_search" "web_fetch_text" "web_extract_images"
    "describe_capabilities")
  "Tool names that may be executed from raw JSON emitted by local models.
Some local models print OpenAI-style JSON tool calls as ordinary assistant text
instead of returning them through gptel's native tool-call channel. This allow
list keeps the compatibility shim read/search oriented."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-raw-tool-confirmation-names
  '("execute_code" "run_elisp" "org_export"
    "write_file" "write_org_file"
    "add_todo" "change_todo_state" "set_deadline" "add_tag")
  "Raw JSON tool-call names that may run only after confirmation.
This covers useful local-model actions that execute code, produce files, or
mutate Org state. They are never auto-executed from raw assistant text unless
confirmation policy is relaxed by the user. The capability gate, the
quarantine pre-flight, and the Advocatus Diaboli skeptic all still apply."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-auto-continue-after-raw-tools t
  "When non-nil, ask the model to continue after raw tool observations.
This turns local-model raw JSON tool-call output into a small ReAct-style chat
loop: tool call, Emacs observation, then a natural-language answer."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-raw-tool-auto-continue-depth 2
  "Maximum nested auto-continuations after raw tool observations.
The default of 2 allows safe read/search chains such as web_search followed by
web_fetch_text while still preventing accidental long loops."
  :type 'integer
  :safe #'integerp
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-trace-buffer-name "*gptel-agent-trace*"
  "Buffer name used for internal agent trace output."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-swarm-buffer-name "*gptel-agent-swarm*"
  "Buffer name used for live organizational swarm activity."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-guardrails-buffer-name "*gptel-agent-guardrails*"
  "Buffer name used for runtime policy and guardrail status."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-workers-buffer-name "*gptel-agent-workers*"
  "Buffer name used for parallel worker lifecycle status."
  :type 'string
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-live-swarm-trace t
  "When non-nil, append agent organization activity to the swarm buffer."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-show-swarm-buffer-on-start t
  "When non-nil, display the swarm buffer when an autonomous session starts."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-show-chat-status-markers t
  "When non-nil, insert compact agent job status markers in gptel buffers."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-show-raw-tool-observations-in-chat nil
  "When non-nil, also insert raw tool observations in the gptel chat buffer.
By default observations are written to `gptel-agent-runtime-trace-buffer-name'
and only the final continuation is inserted in chat."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-hide-raw-tool-calls-in-chat t
  "When non-nil, remove handled raw JSON tool-call text from gptel chat.
The original raw text is still written to the trace buffer."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-execute-raw-tool-calls-in-example-blocks nil
  "When non-nil, raw JSON tool calls inside source/example blocks may execute.
The default nil treats JSON inside Org/Markdown blocks as documentation or
examples, not as live tool requests."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-enable-parallel-mutations t
  "When non-nil, allow non-conflicting write-risk tools to run as workers.
This only applies when the step passes safety checks and confirmation policy
does not require an interactive confirmation."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-parallel-mutation-tool-names
  '("write_file" "write_org_file" "add_todo" "change_todo_state"
    "set_deadline" "add_tag")
  "Mutation tool names that may run in parallel when policy allows it."
  :type '(repeat string)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-json-schema-validator 'auto
  "JSON schema validator preference.
`auto' uses an external validator when configured and available, then falls
back to internal checks. `internal' uses only built-in checks. `external-command'
requires `gptel-agent-runtime-json-schema-command'."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Internal" internal)
                 (const :tag "External command" external-command))
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-json-schema-command "check-jsonschema"
  "External JSON Schema CLI command used when available.
The command must accept: COMMAND --schemafile SCHEMA INSTANCE."
  :type 'string
  :group 'gptel-agent-runtime)

(defvar gptel-agent-runtime-embedding-cache nil
  "Persistent embedding cache alist.")

(defcustom gptel-agent-runtime-blocked-shell-patterns
  '("\\`\\s-*sudo\\b"
    "\\brm\\s-+-rf\\b"
    "\\bdd\\b"
    "\\bmkfs\\b"
    "\\bdiskutil\\s-+erase"
    "\\bchmod\\s-+-R\\s-+777\\b")
  "Shell command regexps blocked by the autonomous runtime."
  :type '(repeat regexp)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-blocked-placeholder-patterns
  '("\\byour[_-]?api[_-]?key\\b"
    "\\bYOUR[_-]?API[_-]?KEY\\b"
    "\\breplace[[:space:]]+.*api[[:space:]_-]*key\\b"
    "\\bapi[_-]?key=your")
  "Regexps for placeholder credentials that must not be executed."
  :type '(repeat regexp)
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-allowed-write-roots
  nil
  "Directories where autonomous write tools may write without extra policy errors.
When nil, write tools rely on confirmation and protected-path checks only."
  :type '(repeat directory)
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

(defcustom gptel-agent-runtime-model-router-enabled nil
  "When non-nil, select backend/model automatically before gptel sends.
The router scores the current request for complexity, introspection, tool risk,
context size, web/current-fact needs, privacy, creativity, and speed/cost. It
then selects the best registered backend matching the chosen profile patterns.
Manual `C-c M' selection still works when this option is nil."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-model-router-default-profile 'local-balanced
  "Fallback model-router profile when no specialist rule matches."
  :type 'symbol
  :group 'gptel-agent-runtime)

(defcustom gptel-agent-runtime-model-router-profiles
  '((local-fast
     :description "Fast/private local model for simple edits and low-risk chat."
     :patterns ("Qwen 2.5 Coder" "Llama 3.2" "Mistral (Ollama)" "Gemma 3")
     :local t)
    (local-balanced
     :description "Default private local model for normal coding/tool work."
     :patterns ("Qwen 2.5 Coder" "Qwen3" "Ministral" "DeepSeek" "Gemma")
     :local t)
    (local-reasoning
     :description "Local reasoning model for planning, debugging, and introspection."
     :patterns ("Ministral" "DeepSeek" "Qwen3" "Gemma 4" "Qwen")
     :local t)
    (cloud-balanced
     :description "Cloud model for complex work when privacy/cost allow it."
     :patterns ("Claude Sonnet" "GPT-4o" "Gemini 2.5 Pro")
     :local nil)
    (cloud-deep
     :description "Strongest available model for high-complexity reasoning."
     :patterns ("Claude Opus" "o3" "o4" "Gemini 2.5 Pro" "Claude Sonnet")
     :local nil)
    (long-context
     :description "Large-context model for long buffers, docs, and repositories."
     :patterns ("Gemini 2.5 Pro" "Claude Sonnet" "Claude Opus" "GPT-4o")
     :local nil)
    (cheap
     :description "Cheap model for low-risk summarization and simple drafting."
     :patterns ("GPT-4o-mini" "Claude Haiku" "Gemma 3" "Llama 3.2")
     :local nil))
  "Model-router profile definitions.
Each profile is (NAME . PLIST). PLIST currently supports :description,
:patterns, and :local. Patterns are matched against display names and model ids
from `my/gptel-backends'."
  :type 'alist
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
  workers
  process
  started-at
  updated-at)

(cl-defstruct (gptel-agent-runtime-worker
               (:constructor gptel-agent-runtime-worker-create))
  "State for one delegated specialist worker."
  id
  session-id
  agent
  step-id
  step-title
  tool
  status
  prompt
  result
  error
  attempts
  max-retries
  handle
  queued-at
  started-at
  updated-at)

(cl-defstruct (gptel-agent-runtime-event
               (:constructor gptel-agent-runtime-event-create))
  "One event in the runtime event bus."
  id
  type
  source
  session-id
  parent-id
  payload
  taint
  created-at)

(cl-defstruct (gptel-agent-runtime-policy-decision
               (:constructor gptel-agent-runtime-policy-decision-create))
  "Decision returned by the runtime policy broker."
  allowed-p
  confirmation-required-p
  reason
  policy
  taint
  metadata)

(cl-defstruct (gptel-agent-runtime-evidence
               (:constructor gptel-agent-runtime-evidence-create))
  "A single piece of evidence flowing through the runtime with provenance.
Evidence is the first-class data carrier produced or consumed by tools, web
fetches, file reads, workers, and user inputs. It carries enough lineage that
downstream code (the policy broker, the reviewer, the trace UI) can decide how
much to trust the data and where it came from.

TEXT is the raw string content. SOURCE-TYPE is one of `user', `tool-result',
`web', `file', `memory', `worker', `runtime', `experiment'. SOURCE-ID identifies
the concrete source (tool name, file path, agent name, URL). TICK records the
OpenClaw substrate clock value when the evidence was created. AGENT is the
agent name that produced or first received the evidence. TAINT is one of
`trusted', `untrusted', `quarantined'. PARENT-EVIDENCE-ID links derived
evidence back to its source so the full lineage DAG can be reconstructed."
  id
  text
  source-type
  source-id
  tick
  agent
  taint
  parent-evidence-id
  created-at)

;; ----- Untrusted-context: append quarantine rule when active -----



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
     :workers nil
     :process gptel-agent-runtime-default-process
     :started-at now
     :updated-at now)))



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
  parallel-p
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
   :parallel-p (plist-get plist :parallel-p)
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


(require 'gptel)


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



;;; --- Security -----------------------------------------------------
;; Confirmation dialog before execution (Babel + AUTORUN). Uses the new
;; gar-response-executor-* names; defvaralias in gar-executor keeps the
;; legacy claude-executor-* names usable by older user configs.
(setq gar-response-executor-confirm-before-execute nil)

;; Automatically execute Babel blocks, exec-tags, auto-commands.
;; t = every Babel block with :results output / :file etc. runs directly
;; after an assistant response and produces visible output (or an image).
(setq gar-response-executor-auto-execute t)

;;; --- Allowed Babel Languages --------------------------------------
(setq gar-response-executor-allowed-languages
      '("python" "sh" "bash" "elisp" "R" "ruby" "js"
        "gnuplot" "dot" "plantuml" "mermaid"))

;;; --- Pattern-Based Auto Commands (example commented out) ----------
;; (setq gar-response-executor-auto-commands
;;       '(("pip install \\(.*\\)" . "pip install \\1")))

;;; --- AUTORUN Whitelist (optional) ---------------------------------
;; nil = no restriction. For more security, enter symbols here:
;; (setq gar-response-executor-allowed-functions
;;       '(find-file find-file-noselect with-current-buffer
;;         goto-char point-max insert save-buffer
;;         org-todo org-insert-heading org-agenda message))

;;; --- Activate Mode ------------------------------------------------
;; Backend + model is set in the "Multi-Backend Configuration" section.
;; gar-response-executor-mode is defined in gar-executor (loaded after
;; this module). The master's tail wiring calls it once gar-executor
;; has provided the function. The legacy claude-executor-mode name is
;; available via defalias for any user config that still binds it.

(provide 'gar-core)

;;; gar-core.el ends here
