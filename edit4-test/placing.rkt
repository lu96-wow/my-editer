#lang racket

;;; edit4-test/placing.rkt —— 打开时的放置选择（单空窗直放 / 多窗让选）

(require rackunit racket/list
         "../edit4/core/world.rkt"
         "../edit4/core/command.rkt"
         "../edit4/core/event.rkt"
         "../edit4/core/scope.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/placing.rkt"
         "../edit4/content/scopes.rkt"
         "../edit4/content/float.rkt"
         "../edit4/layout.rkt")

(define ctx0 (ctx #f (cons 80 24) #f))

;; 造一个文档（有视图，但未绑定到任何窗口）。
(define (make-doc text)
  (define-values (c _did vid) (content-add-doc! (content-blank) text 20 4 text #f))
  (values c vid))

(define-values (cA vidA) (make-doc "A"))
(define-values (cB vidB) (make-doc "B"))

;;; ---------- 单个且空窗口 → 直接放 ----------

(define w1 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content cA))
(define w1* (place-vid! w1 vidA))
(check-false (content-placing (world-content w1*)))          ; 不进 placing
(check-eqv? (content-vid-of (world-content w1*) 0) vidA)     ; 直接绑定
(check-eqv? (world-focus w1*) 0)
(check-true (scope-ok? content-scopes w1* 'editor))

;;; ---------- 单窗已有文档 → 仍直接放（只有多窗才让选） ----------

(define cocc (content-bind cB 0 vidA))
(define wocc (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content cocc))
(define wocc* (place-vid! wocc vidB))
(check-false (content-placing (world-content wocc*)))
(check-eqv? (content-vid-of (world-content wocc*) 0) vidB)    ; 直接替换

;;; ---------- 多窗口 → placing + 循环 / 确认 / 取消 ----------

(define lay2 (split 'h 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                               (child (size 1 #t) (leaf 1 (cons 2 2))))))
(define c2 (content-bind cB 0 vidA))                          ; 窗 0 显示 A，窗 1 空
(define w2 (make-world #:layout lay2 #:focus 0 #:content c2))
(define w2* (place-vid! w2 vidB))
(check-not-false (content-placing (world-content w2*)))
(check-eqv? (content-vid-of (world-content w2*) 1) #f)        ; 还没绑定
(check-false (scope-ok? content-scopes w2* 'editor))          ; 编辑键让位
(check-true (scope-ok? content-scopes w2* 'placing))

(define (run w cmds) (car (run-commands placing-commands ctx0 w cmds)))

;; 循环焦点到窗 1，确认 → 绑到窗 1
(define w3 (run w2* (list (cmd 'place-cycle 1))))
(check-eqv? (world-focus w3) 1)
(define w4 (run w3 (list (cmd 'place-confirm))))
(check-false (content-placing (world-content w4)))
(check-eqv? (content-vid-of (world-content w4) 1) vidB)
(check-eqv? (world-focus w4) 1)

;; 取消 → 清 placing、回 prev-focus、视图不绑定
(define w5 (run w2* (list (cmd 'place-cycle 1))))
(define w6 (run w5 (list (cmd 'place-cancel))))
(check-false (content-placing (world-content w6)))
(check-eqv? (world-focus w6) 0)                               ; 回到进入前焦点
(check-eqv? (content-vid-of (world-content w6) 1) #f)

;;; ---------- 鼠标点：编辑器窗切换目标；面板窗不改状态 ----------

(define lay3 (split 'h 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                               (child (size 1 #t) (leaf 1 (cons 2 2)))
                               (child (size 1 #t) (leaf 2 (cons 2 2))))))
;; 同一个 content 里建：0=编辑器, 1=空, 2=面板（vid 才互异）
(define mc0 (content-blank))
(define-values (mc1 _mda mvA) (content-add-doc! mc0 "A" 20 4 "A" #f))
(define-values (mc2 _mdb mvB) (content-add-doc! mc1 "B" 20 4 "B" #f))
(define-values (mc3 _mdp mpv) (content-add-panel! mc2 "*tree*" 20 4))
(define cc (content-bind (content-bind mc3 0 mvA) 2 mpv))
(define w3p (place-vid! (make-world #:layout lay3 #:focus 0 #:content cc) mvB))
(check-not-false (content-placing (world-content w3p)))

(define fr3 (world-frame w3p (cons 80 24)))
(define (center-of wid)
  (define r (hash-ref (geometry-rects (frame-tiled fr3)) wid))
  (cons (+ (rect-x r) (quotient (rect-w r) 2))
        (+ (rect-y r) (quotient (rect-h r) 2))))
(define (click w wid)
  (define pt (center-of wid))
  (car (run-commands placing-commands
                      (ctx (cursor-event 'press 'left (car pt) (cdr pt)) (cons 80 24) fr3)
                      w (list (cmd 'place-pick)))))

;; 点编辑器窗 1 → 切换到它
(check-eqv? (world-focus (click w3p 1)) 1)
;; 点面板窗 2 → 不改焦点（也不动面板状态）
(check-eqv? (world-focus (click w3p 2)) 0)
(check-eqv? (content-vid-of (world-content (click w3p 2)) 2) mpv)   ; 面板窗内容未动

;; 就算焦点在面板窗，确认也只放到编辑器窗（绝不换掉面板/文件树）
(define w7 (run (world-set-focus w3p 2) (list (cmd 'place-confirm))))
(check-false (content-placing (world-content w7)))
(check-eqv? (content-vid-of (world-content w7) 2) mpv)             ; 面板窗未动
(check-eqv? (content-vid-of (world-content w7) 0) mvB)             ; 放到第一个编辑器窗

;;; ---------- 没有编辑器窗（只有面板）→ 新开一个 ----------

(define nc0 (content-blank))
(define-values (nc1 _ndp nv) (content-add-panel! nc0 "*tree*" 20 4))
(define-values (nc2 _ndd nd) (content-add-doc! nc1 "A" 20 4 "A" #f))
(define wp (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind nc2 0 nv)))
(define wp* (place-vid! wp nd))
(check-false (content-placing (world-content wp*)))
(check-true (> (length (ids (world-layout wp*))) 1))          ; 多了个窗
(check-eqv? (content-vid-of (world-content wp*) (world-focus wp*)) nd)

;;; ---------- 两个编辑器窗互换视图：只换 vid 绑定，几何不变 ----------

(define sw-doc0 (content-blank))
(define-values (sw-c1 _sw-da sw-va) (content-add-doc! sw-doc0 "A" 20 4 "A" #f))
(define-values (sw-c2 _sw-db sw-vb) (content-add-doc! sw-c1 "B" 20 4 "B" #f))
(define sw-lay (split 'h 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                 (child (size 1 #t) (leaf 1 (cons 2 2))))))
(define sw-w (make-world #:layout sw-lay #:focus 0
                         #:content (content-bind (content-bind sw-c2 0 sw-va) 1 sw-vb)))
(check-eqv? (content-vid-of (world-content sw-w) 0) sw-va)
(check-eqv? (content-vid-of (world-content sw-w) 1) sw-vb)
(define sw-w* (run sw-w (list (cmd 'swap-view 0 1))))
(check-eqv? (content-vid-of (world-content sw-w*) 0) sw-vb)   ; 视图换位
(check-eqv? (content-vid-of (world-content sw-w*) 1) sw-va)
(check-equal? (world-layout sw-w*) sw-lay)                    ; 几何/尺寸不动
(check-eqv? (world-focus sw-w*) 0)                            ; 焦点不动

;; 空占位也能换（doc → 空格）
(define sw-w2 (make-world #:layout sw-lay #:focus 0 #:content (content-bind sw-c2 0 sw-va)))
(define sw-w2* (run sw-w2 (list (cmd 'swap-view 0 1))))
(check-eqv? (content-vid-of (world-content sw-w2*) 0) #f)
(check-eqv? (content-vid-of (world-content sw-w2*) 1) sw-va)

;; 'focus / 'next 选择
(define sw-w3 (run (world-set-focus sw-w 0) (list (cmd 'swap-view 'focus 'next))))
(check-eqv? (content-vid-of (world-content sw-w3) 0) sw-vb)
(check-eqv? (content-vid-of (world-content sw-w3) 1) sw-va)

;;; ---------- C-t 两步选取互换：start → cycle → confirm / cancel ----------

(define sd0 (content-blank))
(define-values (sd1 _sdda sva) (content-add-doc! sd0 "A" 20 4 "A" #f))
(define-values (sd2 _sddb svb) (content-add-doc! sd1 "B" 20 4 "B" #f))
(define-values (sd3 _sddc svc) (content-add-doc! sd2 "C" 20 4 "C" #f))
(define sbase (content-bind (content-bind (content-bind sd3 0 sva) 1 svb) 2 svc))
(define s3-lay (split 'h 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                                 (child (size 1 #t) (leaf 1 (cons 2 2)))
                                 (child (size 1 #t) (leaf 2 (cons 2 2))))))
(define sw3 (make-world #:layout s3-lay #:focus 0 #:content sbase))

;; C-t：进入选取，源=0，焦点默认跳到下一个（1）
(define sw3a (run sw3 (list (cmd 'swap-start))))
(check-not-false (content-swap (world-content sw3a)))
(check-eqv? (world-focus sw3a) 1)
;; Tab / M-n：循环目标
(define sw3b (run sw3a (list (cmd 'swap-cycle 1))))
(check-eqv? (world-focus sw3b) 2)
;; c / Enter：确认，0 ↔ 2 互换，几何不动、selection 清掉
(define sw3c (run sw3b (list (cmd 'swap-confirm))))
(check-false (content-swap (world-content sw3c)))
(check-eqv? (content-vid-of (world-content sw3c) 0) svc)
(check-eqv? (content-vid-of (world-content sw3c) 2) sva)
(check-eqv? (content-vid-of (world-content sw3c) 1) svb)
(check-equal? (world-layout sw3c) s3-lay)

;; Esc：取消，焦点回源窗，不换
(define sw3d (run (run sw3 (list (cmd 'swap-start))) (list (cmd 'swap-cycle 1))))
(define sw3e (run sw3d (list (cmd 'swap-cancel))))
(check-false (content-swap (world-content sw3e)))
(check-eqv? (world-focus sw3e) 0)
(check-eqv? (content-vid-of (world-content sw3e) 0) sva)
(check-equal? (world-layout sw3e) s3-lay)

;; 只有一个编辑器窗：无处可换，不进选取
(define sw1 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0
                        #:content (content-bind sw-c2 0 sw-va)))
(check-false (run-commands placing-commands ctx0 sw1 (list (cmd 'swap-start))))

(displayln "edit4/placing.rkt: all tests passed")
