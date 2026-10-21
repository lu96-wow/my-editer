#lang racket

;;; 编辑器着色：逐字符 face 写入、语法 / 同词 / 括号深度组合、增量与 undo 回退。

(require rackunit
         racket/string
         "../main.rkt")

(define engine (make-engine))
(define text "(define x 1)\n")
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "a.rkt"
                 #:path "/tmp/edit-tui-color-test.rkt"
                 #:text text
                 #:key-table (keys)))
(define did 1)
(define vid 1)

(define editor-panel
  (make-panel 'editor 'editor #:views (list vid) #:active vid))
(define layout
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor editor-panel)
               #:focus 'editor))
(define state0
  (make-app-state #:layout layout
                  #:resources store
                  #:area (rect 0 0 40 10)))
(define state (run-actions state0 engine actions))

;; 首次同步：整篇 color-open，并把 face 写进 view。
(define state1 (sync-editor-colors! state engine))
(define f-keyword (engine-view-face-at engine vid 0 1))
(check-true (face? f-keyword))
(check-eq? (face-fg f-keyword) 'syntax-keyword-def)
(check-eq? (face-bg f-keyword) 'bracket-depth-0)

;; 左括号只拿括号底色；标识符同时有同词前景 + 括号背景。
(define f-open (engine-view-face-at engine vid 0 0))
(check-eq? (face-fg f-open) #f)
(check-eq? (face-bg f-open) 'bracket-depth-0)

(define f-x (engine-view-face-at engine vid 0 8))
(check-true (face? f-x))
(check-true (string-prefix? (symbol->string (face-fg f-x)) "word-color-"))
(check-eq? (face-bg f-x) 'bracket-depth-0)

;; 编辑：插入一个外层左括号。pending change 由 run-actions 记录，
;; color sync 只读取、不消费。
(define state2
  (run-actions state1 engine (list (view-action 'insert vid #"("))))
(check-true (pair? (app-state-pending-doc-changes state2)))
(define state3 (sync-editor-colors! state2 engine))
(check-eq? (face-bg (engine-view-face-at engine vid 0 0)) 'bracket-depth-0)
(check-eq? (face-bg (engine-view-face-at engine vid 0 1)) 'bracket-depth-1)
(check-eq? (face-fg (engine-view-face-at engine vid 0 2)) 'syntax-keyword-def)
;; 不消费 pending
(check-true (pair? (app-state-pending-doc-changes state3)))

;; undo/redo 不产生新 change：版本变化时必须退回全量重建，不能沿用旧缓存。
(define state4
  (run-actions state3 engine (list (view-action 'undo vid #f))))
(define state5 (sync-editor-colors! state4 engine))
(check-eq? (face-bg (engine-view-face-at engine vid 0 0)) 'bracket-depth-0)
(check-eq? (face-fg (engine-view-face-at engine vid 0 1)) 'syntax-keyword-def)
(check-eq? (face-bg (engine-view-face-at engine vid 0 1)) 'bracket-depth-0)

;; 相同 key 的重复同步不应不断写 document revision。
(define rev (engine-doc-version engine did))
(define _state6 (sync-editor-colors! (app-state-clear-doc-changes state5) engine))
(check-eq? (engine-doc-version engine did) rev)

(displayln "edit-tui-rebuild/test/color.rkt: ok")
