#lang racket

(require racket/path
         "../../../core/editor.rkt"
         "../../ui/tree.rkt"
         "../state.rkt"
         "../panes.rkt"
         "core.rkt"
         "modal.rkt")

;;; lab/app/actions/tree.rkt —— 文件树上的动作（展开 / 打开 / 新建 / 删除）
;;;
;;; 依赖核心（core.rkt）里的共享原语（app-tree-refresh! / app-open-path! / app-close-path!）
;;; 与 modal.rkt 的 app-begin!；核心不反过来依赖本模块（避免环）。

(provide app-tree-activate! app-tree-new-file! app-tree-new-dir! app-tree-delete!)

(define (app-tree-entry-at-focus a)
  (tree-line->entry (app-tree a)
                    (editor-view-point-line (app-ed a) (panes-tree (app-panes a)))))

;; Enter：目录 → 展开/折叠；文件 → 打开。
(define (app-tree-activate! a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (void)]
        [(entry-dir? e) (file-tree-toggle! (app-tree a) (entry-path e)) (app-tree-refresh! a)]
        [else (app-open-path! a (entry-path e))]))

;; 新建目标的目录：光标在目录上用它，在文件上用其父目录，不在条目上用根。
(define (app-target-dir a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (file-tree-root (app-tree a))]
        [(entry-dir? e) (entry-path e)]
        [else (let-values ([(base _name _dir?) (split-path (entry-path e))]) base)]))

(define (app-tree-new-file! a)
  (define target (app-target-dir a))
  (app-begin! a "new file: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-file! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

(define (app-tree-new-dir! a)
  (define target (app-target-dir a))
  (app-begin! a "new folder: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-dir! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

;; Backspace：确认后删除条目，并同步关掉它（及子路径）已打开的文档。
(define (app-tree-delete! a)
  (define e (app-tree-entry-at-focus a))
  (when e
    (define p (entry-path e))
    (app-begin! a (format "delete ~a? (y/n)" (entry-name e)) #f
                (lambda (yes?)
                  (when yes?
                    (tree-delete-path! p)
                    (app-close-path! a p)
                    (app-tree-refresh! a))))))
