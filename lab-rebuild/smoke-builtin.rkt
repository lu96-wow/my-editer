#lang racket

;;; lab-rebuild/smoke-builtin.rkt —— 内置包冒烟（文件树 / 文档列表）
;;;
;;; 验证：面板 provider 被装配、左栏在树/列表间切换、树能打开文件、列表能展开视图。

(require rackunit
         racket/file
         racket/path
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "app/app.rkt"
         "builtin/tree.rkt"
         "builtin/buffers.rkt"
         "platform/state.rkt"
         "platform/panel.rkt"
         "platform/edit-panes.rkt"
         "platform/paths.rkt"
         "platform/input.rkt"
         "config/keys.rkt")

;;; ---------- 目录准备 ----------

(define root (simplify-path (path->complete-path (make-temporary-file "bi~a" 'directory))))
(define fa (build-path root "a.rkt"))
(define sub (build-path root "sub"))
(with-output-to-file fa #:exists 'replace (lambda () (display "#lang racket\n(define a 1)\n")))
(make-directory sub)
(with-output-to-file (build-path sub "b.rkt") #:exists 'replace (lambda () (display "#lang racket\n(define b 2)\n")))

(define a (app-init root 80 24))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))

;;; ---------- 面板装配 ----------

(check-not-false (app-panel a 'tree))
(check-not-false (app-panel a 'buffers))
(check-true (app-sidebar? a))
(check-equal? (app-left a) 'tree)
(check-true (eqv? (app-focus a) (panel-vid (app-panel a 'tree))))
(check-not-false (screen? (app-render a)))

;;; ---------- 树：展开目录 / 打开文件 ----------

(define (tree-line-of name)
  (for/first ([e (in-list (tree-entries (panel-data (app-panel a 'tree))))] [i (in-naturals)]
              #:when (equal? (entry-name e) name)) i))

(define tvid (panel-vid (app-panel a 'tree)))
(check-not-false (tree-line-of "a.rkt"))
(check-not-false (tree-line-of "sub"))
;; 目录默认收起，子文件不在列表里
(check-false (tree-line-of "b.rkt"))
;; Enter 在 sub 上 → 展开
(editor-view-set-point! (ed) tvid (point (tree-line-of "sub") 0))
(send (key-event 'enter no-mods))
(check-not-false (tree-line-of "b.rkt"))
;; Enter 在 a.rkt 上 → 打开，焦点到编辑区
(editor-view-set-point! (ed) tvid (point (tree-line-of "a.rkt") 0))
(send (key-event 'enter no-mods))
(check-true (edit-panes-contains? (app-edit a) (app-focus a)))
(check-not-equal? (app-focus a) tvid)
(check-true (string-contains? (editor-view-string (ed) (app-focus a)) "(define a 1)"))

;;; ---------- 列表：打开后列出文档 ----------

(define (buf-rows)
  (buffers-rows (ed) (panel-data (app-panel a 'buffers))
                #:exclude (app-internal-vids a)
                #:path-of (lambda (did) (path-table-path (app-paths a) did))))
(check-true (for/or ([r (in-list (buf-rows))]) (string-contains? (buffer-row-name r) "a.rkt")))
;; 文档行默认收起（无 view 行），Enter 展开
(define bvid (panel-vid (app-panel a 'buffers)))
(define (buf-line-of-doc)
  (for/first ([r (in-list (buf-rows))] [i (in-naturals)]
              #:when (eq? (buffer-row-kind r) 'doc)) i))
;; 切到列表面板
(editor-view-set-point! (ed) tvid (point 0 0))
(set-app-focus! a tvid)
(send (key-event 'tab no-mods))
(check-equal? (app-left a) 'buffers)
(check-true (eqv? (app-focus a) bvid))
;; Enter 展开该文档 → 出现 view 行
(editor-view-set-point! (ed) bvid (point (buf-line-of-doc) 0))
(send (key-event 'enter no-mods))
(check-true (for/or ([r (in-list (buf-rows))]) (eq? (buffer-row-kind r) 'view)))

;;; ---------- 左栏开关 / 轮换 ----------

(send (key-event 'b (mods #t #f #f)))                     ; C-b 关侧栏
(check-false (app-sidebar? a))
(check-false (app-left-vid a))
(send (key-event 'b (mods #t #f #f)))                     ; 再开
(check-true (app-sidebar? a))
(check-not-false (app-left-vid a))
(check-not-false (screen? (app-render a)))

(displayln "builtin smoke: ok")
