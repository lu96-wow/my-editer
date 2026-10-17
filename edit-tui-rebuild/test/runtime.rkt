#lang racket

;;; edit-tui-rebuild/test/runtime.rkt —— 块 6：bootstrap / dispatch / effect / state 闭环
;;;
;;; 不启动终端：直接喂 base/event，跑 process-events（dispatch + 解释 effect）。
;;; 运行：racket edit-tui-rebuild/test/runtime.rkt

(require rackunit
         racket/async-channel
         "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../bootstrap/defaults.rkt"
         "../runtime/run.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define erid (region-id 1))
(define srid (region-id 2))

(define engine (make-engine))
(void (engine-create-doc! engine did "main.rkt" "abc\n"))
(void (engine-create-view! engine vid did))

(define ws0
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws did (make-doc-meta "main.rkt" #:path "/tmp/main.rkt"))]
         [ws (workspace-add-view ws vid (view-meta did (hash)))]
         [ws (workspace-add-region ws erid (region erid (list (view-member vid)) vid 'editor))]
         [ws (workspace-add-region ws srid (region srid (list (chrome-member 'status)) 'status 'slot))]
         [lay (make-split 'tb
                          (list (make-leaf erid (flex 1))
                                (make-leaf srid (fixed 1) #:borders '()))
                          (flex 1))])
    (struct-copy workspace ws [layout lay])))

(define s0
  (state-set-focus
   (make-state #:workspace ws0
               #:ids (make-id-counter 2 2 3 1))
   vid))

(define inbox (make-async-channel))
(define (feed s . evs)
  (transition-state (process-events default-env engine inbox s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (meta c)  (app:key-event (key c 'alt)))
(define (ev) (make-engine-view engine))

;;; ════════════════ 编辑 / 导航 ════════════════

(define s1 (feed s0 (plain 'x)))
(check-equal? (engine-view-doc-text (ev) did) "xabc\n")
(check-equal? (engine-view-view-point-column (ev) vid) 1)

(define s2 (feed s1 (plain 'y)))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

(define s3 (feed s2 (app:internal-event 'noop '())))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

(define s4 (feed s3 (plain 'left)))
(check-equal? (engine-view-view-point-column (ev) vid) 1)
(define s5 (feed s4 (plain 'home)))
(check-equal? (engine-view-view-point-column (ev) vid) 0)
(define s6 (feed s5 (plain 'end)))
(check-equal? (engine-view-view-point-column (ev) vid) 5)

;; undo / redo：最后一次编辑是插入 y（当前文本 xyabc），undo 回到 xabc
(define s7 (feed s6 (ctrl 'z)))
(check-equal? (engine-view-doc-text (ev) did) "xabc\n")
(define s8 (feed s7 (ctrl 'y)))
(check-equal? (engine-view-doc-text (ev) did) "xyabc\n")

;; resize
(define s9 (feed s8 (app:resize-event 30 100)))
(check-equal? (window-rows (state-window s9)) 30)
(check-equal? (window-cols (state-window s9)) 100)

;; paste（先 Home，确保落点确定）
(define s9a (feed s9 (plain 'home)))
(define s10 (feed s9a (app:paste-event "P")))
(check-equal? (engine-view-doc-text (ev) did) "Pxyabc\n")

;;; ════════════════ 切分 / 焦点 / 关闭 ════════════════

;; C-b：向右切分，新 view 聚焦
(define s11 (feed s10 (ctrl 'b)))
(check-equal? (hash-count (engine-views engine)) 2)
(check-equal? (hash-count (workspace-views (state-workspace s11))) 2)
(check-equal? (workspace-focus (state-workspace s11)) (view-id 2))
(check-equal? (state-focus s11) (view-id 2))
;; 同 document：两个 view 看同一 buffer
(check-equal? (engine-view-doc-text (ev) (doc-id 1)) "Pxyabc\n")

;; M-left：焦点从右块回到左块
(define s12 (feed s11 (meta 'left)))
(check-equal? (state-focus s12) vid)

;; 点击右块：焦点回到右块（mouse subject 走 geometry）
(define s13 (feed s12 (app:mouse-event (mouse 'press 'left) 1 75)))
(check-equal? (state-focus s13) (view-id 2))

;; C-w：关闭当前 view，焦点回落到另一个 view
(define s14 (feed s13 (ctrl 'w)))
(check-equal? (hash-count (engine-views engine)) 1)
(check-equal? (hash-count (workspace-views (state-workspace s14))) 1)
(check-equal? (state-focus s14) vid)

;;; ════════════════ 退出 ════════════════

(define s15 (feed s14 (ctrl 'q)))
(check-true (runtime-quit? (state-runtime s15)))

(displayln "edit-tui-rebuild runtime: ok")
