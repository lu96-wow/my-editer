#lang racket

;;; 编辑器着色：逐字符 face 写入、语法 / 同词 / 括号深度组合、
;;; 普通编辑增量、首次打开 / undo 后后台全量。

(require rackunit
         racket/async-channel
         racket/string
         "../main.rkt"
         "../config/mode.rkt")

(define (drain-color state)
  (define rt (start-job-runtime color-services #:workers 1))
  (define ch (job-runtime-event-channel rt))
  (define (loop s guard)
    (cond
      [(zero? guard) (error 'drain-color "job drain guard exhausted")]
      [else
       (dispatch-jobs! rt (app-state-jobs s))
       (define pending (job-pending (app-state-jobs s)))
       (cond
         [(null? pending) (stop-job-runtime rt) s]
         [else
          (define ev (async-channel-get ch))
          (define s*
            (handle-color-job-result
             (app-state-finish-job s
                                   (job-result-event-id ev)
                                   (job-result-event-result ev))
             ev))
          (loop s* (sub1 guard))])]))
  (loop state 20))

(define engine (make-engine))
(define text "(define x 1)\n")
(define mode (buffer-mode-for-creation "/tmp/edit-tui-color-test.rkt" text))
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "a.rkt"
                 #:path "/tmp/edit-tui-color-test.rkt"
                 #:text text
                 #:key-table (buffer-mode-key-table mode)
                 #:mode mode))
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

;; 首次打开：sync 提交后台 color-open；结果回来后再 sync 写 face。
(define state-pending (sync-editor-colors! state engine))
(check-true (pair? (job-pending (app-state-jobs state-pending))))
(define state-ready (drain-color state-pending))
(check-equal? (job-pending (app-state-jobs state-ready)) '())
(define state1 (sync-editor-colors! state-ready engine))
(check-eq? (face-fg (engine-view-face-at engine vid 0 1)) 'syntax-keyword-def)
(check-eq? (face-bg (engine-view-face-at engine vid 0 1)) 'bracket-depth-0)

;; 左括号只拿括号底色；标识符同时有同词前景 + 括号背景。
(define f-open (engine-view-face-at engine vid 0 0))
(check-eq? (face-fg f-open) #f)
(check-eq? (face-bg f-open) 'bracket-depth-0)

(define f-x (engine-view-face-at engine vid 0 8))
(check-true (face? f-x))
(check-true (string-prefix? (symbol->string (face-fg f-x)) "word-color-"))
(check-eq? (face-bg f-x) 'bracket-depth-0)

;; 光标正在 token 内：暂时抑制 word-color；移开后恢复。
(define cursor-in-x
  (run-actions state1 engine
               (list (view-action 'select vid
                                  (selections-one (caret (point 0 8)))))))
(define cursor-in-x* (sync-editor-colors! cursor-in-x engine))
(check-false (face-fg (engine-view-face-at engine vid 0 8)))
(define cursor-away
  (run-actions cursor-in-x* engine
               (list (view-action 'select vid
                                  (selections-one (caret (point 0 0)))))))
(define cursor-away* (sync-editor-colors! cursor-away engine))
(check-true (string-prefix? (symbol->string (face-fg (engine-view-face-at engine vid 0 8)))
                            "word-color-"))
(set! state1 cursor-away*)

;; 边界：有 path 的 text mode 即使内容像 Racket，也不写着色 face。
(define text-mode* (buffer-mode-for-creation "b.txt" "(define x 1)"))
(define-values (text-store text-actions)
  (resource-open (app-state-resources state1)
                 #:name "b.txt"
                 #:path "/tmp/edit-tui-color-test.txt"
                 #:text "(define x 1)"
                 #:key-table (buffer-mode-key-table text-mode*)
                 #:mode text-mode*))
(define text-state
  (run-actions (struct-copy app-state state1 [resources text-store])
               engine text-actions))
(define text-state* (sync-editor-colors! text-state engine))
(check-false (engine-view-face-at engine 2 0 1))

;; 普通编辑：主线程增量，不产生 color job。
(define state2
  (run-actions state1 engine (list (view-action 'insert vid #"("))))
(check-true (pair? (app-state-pending-doc-changes state2)))
(define state3 (sync-editor-colors! state2 engine))
(check-equal? (job-pending (app-state-jobs state3)) '())
(check-eq? (face-bg (engine-view-face-at engine vid 0 0)) 'bracket-depth-0)
(check-eq? (face-bg (engine-view-face-at engine vid 0 1)) 'bracket-depth-1)
(check-eq? (face-fg (engine-view-face-at engine vid 0 2)) 'syntax-keyword-def)
;; 不消费 pending
(check-true (pair? (app-state-pending-doc-changes state3)))

;; undo/redo 不产生新 change：版本变化时提交后台全量，不能沿用旧缓存。
(define state4
  (run-actions state3 engine (list (view-action 'undo vid #f))))
(define state5-pending (sync-editor-colors! state4 engine))
(check-true (pair? (job-pending (app-state-jobs state5-pending))))
(define state5-ready (drain-color state5-pending))
(define state5 (sync-editor-colors! state5-ready engine))
(check-eq? (face-bg (engine-view-face-at engine vid 0 0)) 'bracket-depth-0)
(check-eq? (face-fg (engine-view-face-at engine vid 0 1)) 'syntax-keyword-def)
(check-eq? (face-bg (engine-view-face-at engine vid 0 1)) 'bracket-depth-0)

;; 后台结果回来前文档继续变化：旧结果必须丢弃，并重新请求当前版本。
;; 一次事件里两次编辑 -> 走后台全量。
(define s6 (run-actions state5 engine
                         (list (view-action 'insert vid #"A")
                               (view-action 'insert vid #"B"))))
(define s7 (sync-editor-colors! s6 engine))
(check-true (pair? (job-pending (app-state-jobs s7))))
;; job 还没回来，继续编辑。
(define s8 (run-actions s7 engine (list (view-action 'insert vid #"C"))))
(define s9 (drain-color s8)) ; 旧 job 结果先回来
(define s10 (sync-editor-colors! s9 engine)) ; 检测 stale，提交当前版本
(check-true (pair? (job-pending (app-state-jobs s10))))
(define s11 (sync-editor-colors! (drain-color s10) engine))
(check-equal? (job-pending (app-state-jobs s11)) '())
(check-true (string-contains? (engine-view-text engine vid) "ABC"))

;; 后台 job 失败：当前版本标记为 failed，不反复重试；文本版本变化后再试。
(define f1 (run-actions s11 engine
                        (list (view-action 'insert vid #"A")
                              (view-action 'insert vid #"B"))))
(define f2 (sync-editor-colors! f1 engine))
(define failed-job (car (job-pending (app-state-jobs f2))))
(define fail-ev (job-result-event (job-id failed-job) 'color-open
                                 (job-error "boom") (job-tag failed-job)))
(define f3
  (handle-color-job-result
   (app-state-finish-job f2 (job-id failed-job) (job-error "boom"))
   fail-ev))
(define f4 (sync-editor-colors! f3 engine))
(check-equal? (job-pending (app-state-jobs f4)) '())
(define f5 (run-actions f4 engine (list (view-action 'insert vid #"C"))))
(define f6 (sync-editor-colors! f5 engine))
(check-true (pair? (job-pending (app-state-jobs f6))))
(define f7 (sync-editor-colors! (drain-color f6) engine))
(check-equal? (job-pending (app-state-jobs f7)) '())

;; 相同 key 的重复同步不应不断写 document revision。
(define rev (engine-doc-version engine did))
(define _state12 (sync-editor-colors! (app-state-clear-doc-changes f7) engine))
(check-eq? (engine-doc-version engine did) rev)

(displayln "edit-tui-rebuild/test/color.rkt: ok")
