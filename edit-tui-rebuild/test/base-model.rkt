#lang racket

;;; edit-tui-rebuild/test/base-model.rkt —— base + model 的第一块自检
;;;
;;; 只测纯数据和纯变换；不 require tui / core。
;;; 运行：racket edit-tui-rebuild/test/base-model.rkt

(require rackunit
         "../base/id.rkt"
         "../base/event.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/layout.rkt"
         "../model/workspace.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../model/state.rkt")

;;; ════════════════ id ════════════════

(define c0 (make-id-counter))
(define-values (d1 c1) (id-counter-next c0 'doc))
(define-values (d2 c2) (id-counter-next c1 'doc))
(define-values (v1 c3) (id-counter-next c2 'view))
(define-values (r1 c4) (id-counter-next c3 'region))
(define-values (j1 c5) (id-counter-next c4 'job))

(check-equal? d1 (doc-id 1))
(check-equal? d2 (doc-id 2))
(check-equal? v1 (view-id 1))
(check-equal? r1 (region-id 1))
(check-equal? j1 (job-id 1))
(check-true (doc-id? d1))
(check-false (doc-id? v1))
(check-true (view-id? v1))
(check-false (view-id? d1))
(check-equal? (id->string d1) "doc:1")
(check-true (id=? d1 (doc-id 1)))
(check-false (id=? d1 d2))

;; 分配器是纯的：同一个 counter 重放得到同一 id。
(check-equal? (call-with-values (λ () (id-counter-next c0 'doc)) (λ (i _) i)) d1)

;;; ════════════════ event / effect ════════════════

(define kev (key-event 'k))
(define mev (mouse-event 'm 3 4))
(check-equal? (event-kind kev) 'key)
(check-equal? (event-kind mev) 'mouse)
(check-equal? (mouse-event-row mev) 3)
(check-equal? (mouse-event-col mev) 4)
(check-equal? (event-kind (resize-event 24 80)) 'resize)
(check-equal? (event-kind (paste-event "x")) 'paste)
(check-equal? (event-kind (internal-event 'job-done 'v)) 'internal)
(check-equal? (event-kind (tick-event 't)) 'tick)
(check-equal? (event-kind (quit-event)) 'quit)
(check-true (event? kev))
(check-false (event? 'k))

(check-equal? (effect-kind (edit-effect v1 'op)) 'edit)
(check-equal? (effect-kind (select-effect v1 'sel)) 'select)
(check-equal? (effect-kind (scroll-effect v1 3)) 'scroll)
(check-equal? (effect-kind (open-doc-effect 'spec values)) 'open-doc)
(check-equal? (effect-kind (close-doc-effect d1)) 'close-doc)
(check-equal? (effect-kind (save-doc-effect d1 values)) 'save-doc)
(check-equal? (effect-kind (read-file-effect "x" values)) 'read-file)
(check-equal? (effect-kind (write-file-effect "x" "t" values)) 'write-file)
(check-equal? (effect-kind (spawn-effect j1 (λ () 1))) 'spawn)
(check-equal? (effect-kind (timer-effect 10 kev)) 'timer)
(check-equal? (effect-kind (emit-effect kev)) 'emit)
(check-equal? (effect-kind (quit-effect)) 'quit)
(check-true (effect? (quit-effect)))
(check-false (effect? kev))

;;; ════════════════ transition ════════════════

(define e1 (emit-effect kev))
(define e2 (quit-effect))
(define t1 (transition (make-state) (list e1)))
(define t2 (transition-bind t1 (λ (s) (transition (state-mark-quit s) (list e2)))))
(check-equal? (transition-effects t2) (list e1 e2))
(check-true (runtime-quit? (state-runtime (transition-state t2))))
(check-equal? (transition-effects (transition-pure (make-state))) '())

;; transition-all 保持顺序
(define t3 (transition-all
            (transition (make-state) (list e1))
            (transition (make-state) (list e2))))
(check-equal? (transition-effects t3) (list e1 e2))

;;; ════════════════ layout ════════════════

(define ra (region-id 1))
(define rb (region-id 2))
(define rc (region-id 3))
(define rd (region-id 4))

(define lt (tree-split (make-leaf ra (fixed 8)) ra 'lr rb))
(check-equal? (tree-regions lt) (list ra rb))
(check-true (tree-contains? lt ra))
(check-false (tree-contains? lt rc))
(check-true (tree-visible? lt rb))

;; 同轴再插：n 叉，不加深
(define lt2 (tree-split lt rb 'lr rc))
(check-equal? (tree-regions lt2) (list ra rb rc))
(check-equal? (split-axis lt2) 'lr)

;; 异轴插：嵌套
(define lt3 (tree-split lt2 rb 'tb rd))
(check-equal? (tree-regions lt3) (list ra rb rd rc))

;; 关闭：删叶 + 单孩子 split 塌缩；塌缩继承 split 的 dim
(define lt4 (tree-close lt3 rd))
(check-equal? (tree-regions lt4) (list ra rb rc))
(define ltz1 (tree-split (make-leaf ra (fixed 8)) ra 'lr rb))
(define ltz2 (tree-close ltz1 rb))
(check-equal? (leaf-dim (tree-find ltz2 ra)) (fixed 8))

;; 摘除
(define-values (lt5 removed) (tree-detach lt3 rc))
(check-equal? (tree-regions lt5) (list ra rb rd))
(check-true (leaf? removed))
(check-equal? (leaf-region removed) rc)

;; 移动
(define lt6 (tree-move lt3 ra rb 'tb #:side 'after))
(check-equal? (tree-regions lt6) (list rb ra rd rc))
;; 目标不存在 / 目标是自身 → 原样
(check-equal? (tree-regions (tree-move lt3 ra (region-id 99) 'lr)) (tree-regions lt3))
(check-equal? (tree-regions (tree-move lt3 ra ra 'lr)) (tree-regions lt3))

;; 显隐：隐藏保留 dim，恢复回来
(define lt7 (tree-hide lt2 ra))
(check-false (tree-visible? lt7 ra))
(check-equal? (tree-visible-regions lt7) (list rb rc))
(check-equal? (leaf-dim (tree-find lt7 ra)) (leaf-dim (tree-find lt2 ra)))
(check-equal? (tree-visible-regions (tree-show lt7 ra)) (list ra rb rc))

;; 改 dim
(check-equal? (leaf-dim (tree-find (tree-set-dim lt2 rb (fixed 3)) rb)) (fixed 3))

;;; ════════════════ workspace ════════════════

(define did (doc-id 1))
(define vid1 (view-id 1))
(define vid2 (view-id 2))
(define rid (region-id 1))

(define ws0
  (make-workspace #:layout (make-leaf rid)))
(define ws1
  (workspace-add-doc ws0 did (make-doc-meta "main.rkt" #:path "/tmp/main.rkt")))
(define ws2
  (workspace-add-view ws1 vid1 (view-meta did (hash))))
(define ws3
  (workspace-add-view ws2 vid2 (view-meta did (hash))))
(define ws4
  (workspace-add-region ws3 rid
                        (region rid
                                (list (view-member vid1) (view-member vid2))
                                vid1
                                'editor)))

(check-equal? (doc-meta-name (workspace-doc ws4 did)) "main.rkt")
(check-equal? (doc-meta-path (workspace-doc ws4 did)) "/tmp/main.rkt")
(check-equal? (workspace-doc-of-view ws4 vid1) did)
(check-equal? (region-key (workspace-view-region ws4 vid2)) rid)
(check-equal? (workspace-region-views ws4 rid) (list vid1 vid2))
(check-equal? (workspace-region-active ws4 rid) vid1)

;; 焦点 + 历史
(define ws5 (workspace-set-focus ws4 vid1))
(check-equal? (workspace-focus-view ws5) vid1)
(define ws6 (workspace-set-focus ws5 vid2))
(check-equal? (workspace-focus-view ws6) vid2)
(check-equal? (workspace-stack ws6) (list vid1))
(define ws7 (workspace-pop-focus ws6))
(check-equal? (workspace-focus-view ws7) vid1)
(check-equal? (workspace-stack ws7) '())
;; 不压栈恢复
(check-equal? (workspace-stack (workspace-set-focus* ws5 vid2 #:push? #f)) '())

;; 关闭文档：doc + 它所有 view + focus/stack 一并清
(define ws8 (workspace-remove-doc ws6 did))
(check-false (workspace-doc ws8 did))
(check-false (workspace-view ws8 vid1))
(check-false (workspace-view ws8 vid2))
(check-false (workspace-focus ws8))
(check-equal? (workspace-stack ws8) '())

;;; ════════════════ input / chrome ════════════════

(define in0 (input-empty))
(check-false (input-pending? in0))
(define in1 (input-set-pending in0 (list 'a 'b)))
(check-true (input-pending? in1))
(check-equal? (input-pending (input-clear-pending in1)) '())
(check-equal? (input-modes (input-push-mode in0 'overlay)) '(overlay))
(check-equal? (input-modes (input-pop-mode (input-push-mode in0 'overlay))) '())
(check-equal? (gesture-kind (make-gesture 'seam #f 'data)) 'seam)
(check-false (idle-gesture? (make-gesture 'seam #f 'data)))
(check-true (idle-gesture? #f))

(define ch0 (chrome-empty))
(check-equal? (chrome-message ch0) "")
(check-equal? (chrome-message (chrome-set-message ch0 "hi")) "hi")
(check-equal? (chrome-log (chrome-log-append ch0 "a")) '("a"))
(check-equal? (chrome-log (chrome-log-append (chrome-log-append ch0 "a") "b")) '("b" "a"))

;;; ════════════════ state ════════════════

(define s0 (state-empty))
(check-equal? (state-focus s0) #f)
(check-equal? (runtime-revision (state-runtime s0)) 0)
(check-equal? (runtime-revision (state-runtime (state-bump-revision s0))) 1)
(check-true (runtime-quit? (state-runtime (state-mark-quit s0))))

;; 纯分配
(define-values (sd s1) (state-next-id s0 'doc))
(define-values (sv s2) (state-next-id s1 'view))
(define-values (sr s3) (state-next-id s2 'region))
(check-equal? sd (doc-id 1))
(check-equal? sv (view-id 1))
(check-equal? sr (region-id 1))
;; 原 state 不变
(check-equal? (state-ids s0) (make-id-counter))
(check-equal? (state-ids s3) (id-counter 2 2 2 1))

;; 切片更新不互相污染
(define s4 (state-set-workspace s3 ws6))
(check-equal? (state-focus s4) vid2)
(check-equal? (state-focus s3) #f)
(check-equal? (state-workspace s3) (workspace-empty))

(displayln "edit-tui-rebuild base/model: ok")
