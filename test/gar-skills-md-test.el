;;; gar-skills-md-test.el --- ERT tests for gar-skills-md -*- lexical-binding: t; -*-

;;; Code:

(require 'test-helper)

;; --- frontmatter parser ---

(ert-deftest gar-skills-md-parses-key-value-frontmatter ()
  "Frontmatter key:value lines become a plist with keyword keys."
  (let ((plist (gptel-agent-runtime--skills-md-parse-frontmatter
                "id: write-config\nsummary: Write configs reliably")))
    (should (equal "write-config" (plist-get plist :id)))
    (should (equal "Write configs reliably" (plist-get plist :summary)))))

(ert-deftest gar-skills-md-parses-comma-separated-triggers ()
  "List-valued frontmatter keys split on commas."
  (let ((plist (gptel-agent-runtime--skills-md-parse-frontmatter
                "triggers: config, file, write")))
    (should (equal '("config" "file" "write")
                   (plist-get plist :triggers)))))

(ert-deftest gar-skills-md-parses-bracketed-list ()
  "[a, b, c] bracket syntax also parses as a list."
  (let ((plist (gptel-agent-runtime--skills-md-parse-frontmatter
                "triggers: [alpha, beta, gamma]")))
    (should (equal '("alpha" "beta" "gamma")
                   (plist-get plist :triggers)))))

;; --- frontmatter / body extraction ---

(ert-deftest gar-skills-md-extracts-frontmatter-and-body ()
  "Splitting --- delimited frontmatter from the body."
  (let* ((text "---\nid: x\nsummary: y\n---\n\n# x\n\nProse here.")
         (parts (gptel-agent-runtime--skills-md-extract-frontmatter text)))
    (should (string-match-p "id: x" (car parts)))
    (should (string-match-p "Prose here" (cdr parts)))))

(ert-deftest gar-skills-md-no-frontmatter-returns-text-as-body ()
  (let* ((text "# A skill without frontmatter")
         (parts (gptel-agent-runtime--skills-md-extract-frontmatter text)))
    (should (null (car parts)))
    (should (string= text (cdr parts)))))

;; --- elisp code block extraction ---

(ert-deftest gar-skills-md-extracts-first-elisp-code-block ()
  (let* ((text "Some prose.\n\n```elisp\n((:title \"T\"))\n```\n\nMore prose.")
         (block (gptel-agent-runtime--skills-md-extract-elisp-block text)))
    (should (string-match-p ":title" block))))

(ert-deftest gar-skills-md-no-elisp-block-returns-nil ()
  (should-not (gptel-agent-runtime--skills-md-extract-elisp-block
               "Just prose.")))

;; --- full skill parse ---

(ert-deftest gar-skills-md-parses-complete-skill-file ()
  "End-to-end parse of a full markdown skill."
  (let* ((md "---
id: write-config
summary: Write configs reliably
triggers: config, file, write
---

# write-config

Free prose.

## Steps

```elisp
((:title \"Verify\" :tool \"read_file\" :args (:path \"/tmp/x\"))
 (:title \"Write\" :tool \"write_file\" :args (:path \"/tmp/x\" :content \"...\")))
```

## Notes

Variants.")
         (skill (gptel-agent-runtime-skill-from-markdown md)))
    (should skill)
    (should (equal "write-config" (plist-get skill :id)))
    (should (equal "Write configs reliably" (plist-get skill :summary)))
    (should (equal '("config" "file" "write")
                   (plist-get skill :triggers)))
    (should (= 2 (length (plist-get skill :steps))))
    (should (equal "Verify"
                   (plist-get (car (plist-get skill :steps)) :title)))))

(ert-deftest gar-skills-md-skill-without-id-returns-nil ()
  "A skill file without an id in the frontmatter parses to nil."
  (should-not (gptel-agent-runtime-skill-from-markdown
               "---\nsummary: only summary\n---\n\nNo id here.")))

;; --- serializer round-trip ---

(ert-deftest gar-skills-md-serialize-deserialize-round-trip ()
  "Writing a skill to markdown then parsing it back preserves the id +
summary + triggers + steps shape."
  (let* ((skill `(:id "rt-skill"
                  :summary "Round trip test"
                  :triggers ("alpha" "beta")
                  :steps ((:title "Step 1" :tool "read_file"
                           :args (:path "/tmp/x"))
                          (:title "Step 2" :tool "write_file"
                           :args (:path "/tmp/y")))))
         (md (gptel-agent-runtime-skill-to-markdown skill))
         (parsed (gptel-agent-runtime-skill-from-markdown md)))
    (should parsed)
    (should (equal "rt-skill" (plist-get parsed :id)))
    (should (equal "Round trip test" (plist-get parsed :summary)))
    (should (equal '("alpha" "beta") (plist-get parsed :triggers)))
    (should (= 2 (length (plist-get parsed :steps))))
    (should (equal "Step 1"
                   (plist-get (car (plist-get parsed :steps)) :title)))))

;; --- file IO ---

(ert-deftest gar-skills-md-read-write-file ()
  "skill-to-file + skill-from-file round-trip through disk."
  (let* ((tmp (make-temp-file "gar-skill-test-" nil ".md"))
         (skill `(:id "file-test"
                  :summary "Persisted"
                  :triggers ("a")
                  :steps ((:title "X")))))
    (unwind-protect
        (progn
          (gptel-agent-runtime-skill-to-file skill tmp)
          (let ((loaded (gptel-agent-runtime-skill-from-file tmp)))
            (should (equal "file-test" (plist-get loaded :id)))
            (should (equal "Persisted" (plist-get loaded :summary)))))
      (ignore-errors (delete-file tmp)))))

;; --- bridge to playbook + auto-register ---

(ert-deftest gar-skills-md-skill-to-playbook ()
  "The skill->playbook bridge produces a playbook struct."
  (let* ((skill `(:id "p1" :summary "X" :triggers ("t1")
                  :steps ((:title "s"))))
         (pb (gptel-agent-runtime--skills-md-skill->playbook skill)))
    (should (gptel-agent-runtime-playbook-p pb))
    (should (equal "p1" (gptel-agent-runtime-playbook-id pb)))
    (should (equal "X" (gptel-agent-runtime-playbook-summary pb)))
    (should (equal '("t1") (gptel-agent-runtime-playbook-triggers pb)))))

(ert-deftest gar-skills-md-register-replaces-existing ()
  "Registering a playbook with an existing id replaces the old entry."
  (let* ((pb-old (gptel-agent-runtime-playbook-create
                  :id "dup" :summary "old"))
         (pb-new (gptel-agent-runtime-playbook-create
                  :id "dup" :summary "new"))
         (gptel-agent-runtime-playbook-registry (list pb-old)))
    (gptel-agent-runtime--skills-md-register-playbook pb-new)
    (should (= 1 (length gptel-agent-runtime-playbook-registry)))
    (should (equal "new"
                   (gptel-agent-runtime-playbook-summary
                    (car gptel-agent-runtime-playbook-registry))))))

;; --- directory loader ---

(ert-deftest gar-skills-md-load-directory ()
  "load-skills-from-directory loads each .md and registers them as playbooks."
  (let* ((tmp-dir (make-temp-file "gar-skills-test-" t))
         (gptel-agent-runtime-skills-directory tmp-dir)
         (gptel-agent-runtime-skills-auto-register t)
         (gptel-agent-runtime-playbook-registry nil))
    (unwind-protect
        (progn
          (gptel-agent-runtime-skill-to-file
           '(:id "dir-1" :summary "s1" :triggers ("a")
             :steps ((:title "x")))
           (expand-file-name "skill1.md" tmp-dir))
          (gptel-agent-runtime-skill-to-file
           '(:id "dir-2" :summary "s2" :triggers ("b")
             :steps ((:title "y")))
           (expand-file-name "skill2.md" tmp-dir))
          (let ((n (gptel-agent-runtime-load-skills-from-directory)))
            (should (= 2 n))
            (should (= 2 (length gptel-agent-runtime-playbook-registry)))))
      (delete-directory tmp-dir t))))

;; --- emit-candidate-as-markdown ---

(ert-deftest gar-skills-md-emit-candidate-writes-md-sibling ()
  "The emitter writes a .md alongside an .el path."
  (let* ((tmp-dir (make-temp-file "gar-emit-test-" t))
         (el-file (expand-file-name "candidate.el" tmp-dir))
         (candidate '(:id "c1" :status candidate :summary "refined"
                      :triggers ("a") :steps ((:title "x"))))
         (gptel-agent-runtime-skills-refinement-emit-markdown t))
    (unwind-protect
        (let ((md-file (gptel-agent-runtime-emit-candidate-as-markdown
                        candidate el-file)))
          (should md-file)
          (should (file-exists-p md-file))
          (should (string-suffix-p ".md" md-file)))
      (delete-directory tmp-dir t))))

(provide 'gar-skills-md-test)

;;; gar-skills-md-test.el ends here
