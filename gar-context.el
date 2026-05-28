;;; gar-context.el --- image capture and web fetch helpers -*- lexical-binding: t; -*-

;; Part of deno1011/gptel-agent-runtime. Extracted from the monolith
;; gptel-agent-runtime.org on 2026-05-26 as PR 1 of the module split.

;;; Commentary:

;; Provides:
;;  - clipboard image capture and shrink (`my/insert-clipboard-image',
;;    `my/gptel-attach-image-at-point', `my/--shrink-image')
;;  - org-download screenshot integration
;;  - web fetch helpers (`my/web-fetch', `my/web-html', `my/web-text',
;;    `my/web-search-ddg', `my/web-fetch-image', `my/web-extract-images',
;;    `my/insert-image-inline')

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'shr)
(require 'dom)

(defcustom gptel-agent-runtime-image-helper-required nil
  "When non-nil, image-capture entry points hard-error when the OS helper is missing.
Default is nil: capture functions warn and return nil rather than aborting,
so a missing helper does not break the rest of the session."
  :type 'boolean
  :group 'gptel-agent-runtime)

(defun gptel-agent-runtime--image-helper-name ()
  "Return the name of the OS clipboard-image helper for the current platform."
  (pcase system-type
    ('darwin "pngpaste")
    ('gnu/linux "xclip")
    (_ nil)))

(defun gptel-agent-runtime--image-helper-available-p ()
  "Return non-nil when the platform's clipboard-image helper is on PATH."
  (when-let ((helper (gptel-agent-runtime--image-helper-name)))
    (executable-find helper)))

;;;###autoload
(defun gptel-agent-runtime-install-image-helpers ()
  "Install the OS-native clipboard-image helper interactively.
On macOS uses Homebrew to install `pngpaste'; on Linux uses apt to
install `xclip'. The package does not call this at load time -- run it
manually once when you want clipboard image capture to work."
  (interactive)
  (pcase system-type
    ('darwin
     (cond
      ((executable-find "pngpaste")
       (message "pngpaste already installed at %s" (executable-find "pngpaste")))
      ((not (executable-find "brew"))
       (user-error "brew not found — install Homebrew first, then re-run M-x gptel-agent-runtime-install-image-helpers"))
      (t
       (start-process "install-pngpaste" "*install-pngpaste*"
                      "brew" "install" "pngpaste")
       (message "pngpaste installing via brew in background; check *install-pngpaste*."))))
    ('gnu/linux
     (cond
      ((executable-find "xclip")
       (message "xclip already installed at %s" (executable-find "xclip")))
      (t
       (let ((sudo-p (executable-find "sudo")))
         (apply #'start-process "install-xclip" "*install-xclip*"
                (if sudo-p
                    (list "sudo" "apt-get" "install" "-y" "xclip")
                  (list "apt-get" "install" "-y" "xclip")))
         (message "xclip installing via apt in background; check *install-xclip*.")))))
    (_
     (user-error "Automatic install only supported on darwin / gnu/linux; install the clipboard-image helper manually."))))

(defcustom my/gptel-image-dir
  (expand-file-name "gptel-images" user-emacs-directory)
  "Directory for images inserted via `my/insert-clipboard-image'."
  :type 'directory
  :group 'gar-response-executor)

(defcustom my/gptel-image-max-dim 1600
  "Maximum edge length in pixels.
Larger images are resized via sips. iPhone photos (4032×3024)
as PNG are ~15 MB → resize to 1600 px edge + optional JPEG: <500 KB.
The 5 MB raw upload limit is the strictest mainstream provider's cap;
Base64 encoding (+33%) hits that at ~3.75 MB. Stay well below to be safe."
  :type 'integer
  :group 'gar-response-executor)

(defcustom my/gptel-image-max-bytes (* 2 1024 1024)
  "Soft-limit image size in bytes (2 MB).
If exceeded after resize → convert to JPEG q=85.
Conservative due to Base64 overhead (~33%): 2 MB raw → ~2.7 MB encoded,
safely below the strictest 5 MB provider limit."
  :type 'integer
  :group 'gar-response-executor)

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

(defcustom my/web-fetch-timeout 30
  "Timeout in seconds for `my/web-fetch'."
  :type 'integer
  :group 'gar-response-executor)

(defcustom my/web-user-agent "Emacs-Gptel-Agent-Helper"
  "User-Agent string for web requests."
  :type 'string
  :group 'gar-response-executor)

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

(provide 'gar-context)

;;; gar-context.el ends here
