#lang racket

;;; 鼠标拖动选中区域：press 落 caret + 记 select-drag，move 扩展 head，
;;; release 结束（选区留在 view 里）。

(require rackunit
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt"
         "../main.rkt")

(define area (rect 0 0 20 6))

(define (make-state text #:borders [borders '()])
  (define engine (make-engine))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "main"
                   #:text text
                   #:key-table (buffer-key-table #f text)))
  (define editor-panel
    (make-panel 'editor 'editor #:views '(1) #:active 1 #:borders borders))
  (define layout
    (make-layout #:root (make-leaf 'editor)
                 #:panels (hash 'editor editor-panel)
                 #:focus 'editor))
  (define state
    (make-app-state #:layout layout
                    #:resources store
                    #:keymap default-keymap
                    #:area area))
  (define s0 (run-actions state engine actions))
  (let-values ([(cache bytes) (render-frame s0 engine #f)])   ; 首帧落 viewport 尺寸
    (void cache)
    (void bytes))
  (values s0 engine))

;; 鼠标事件 -> (values state actions)，标点动作由 engine 解释。
(define (mouse* state engine token row col)
  (define-values (s actions) (step state (mouse-event token row col)))
  (values (run-actions s engine actions) actions))

(define (mouse state engine token row col)
  (let-values ([(s actions) (mouse* state engine token row col)])
    (void actions)
    s))

(define (press* state engine tok)
  (define-values (s actions) (step state (key-event tok)))
  (values (run-actions s engine actions) actions))

(define (press state engine tok)
  (let-values ([(s actions) (press* state engine tok)])
    (void actions)
    s))

;;; ---------- 同行拖动：press 落 caret，move 扩展选区 ----------
(define-values (s0 e0) (make-state "abcdef\nghijkl"))

(define-values (s1 a1) (mouse* s0 e0 'press 0 1))
(check-equal? (map view-action-kind a1) '(point))
(check-equal? (view-action-data (car a1)) '(0 1 #f))
(check-equal? (app-state-select-drag s1) (select-drag 'editor 1))
(check-equal? (app-state-focus-panel-id s1) 'editor)

(define-values (s2 a2) (mouse* s1 e0 'move 0 4))
(check-equal? (map view-action-kind a2) '(point))
(check-equal? (view-action-data (car a2)) '(0 4 #t))
;; 拖动期间焦点不变，选择始终留在按下的 panel。
(check-equal? (app-state-focus-panel-id s2) 'editor)

;; 选区是 [1,4)：直接打字会替换掉。
(define s3 (press s2 e0 (key 'X)))
(check-equal? (engine-view-text e0 1) "aXef\nghijkl")
;; 按键结束拖选手势（不会让后续 move 继续扩展）。
(check-false (app-state-select-drag s3))

;;; ---------- 跨行拖动 ----------
(define-values (m0 me) (make-state "abcdef\nghijkl"))
(define m1 (mouse m0 me 'press 0 2))
(define m2 (mouse m1 me 'move 1 3))
(define m3 (mouse m2 me 'release 1 3))
(check-false (app-state-select-drag m3))
(define m4 (press m3 me (key 'backspace)))
(check-equal? (engine-view-text me 1) "abjkl")

;;; ---------- release 结束拖动，选区保留 ----------
(define-values (r0 re) (make-state "abcdef\nghijkl"))
(define r1 (mouse r0 re 'press 0 1))
(define r2 (mouse r1 re 'move 0 4))
(define r3 (mouse r2 re 'release 0 4))
(check-false (app-state-select-drag r3))
(define r4 (press r3 re (key 'X)))
(check-equal? (engine-view-text re 1) "aXef\nghijkl")

;;; ---------- 拖到内容区下方：先滚一行，再落到最近可见行 ----------
(define-values (b0 be) (make-state "abcdef\nghijkl"))
(define b1 (mouse b0 be 'press 0 1))
(define-values (b2 ba2) (mouse* b1 be 'move 10 3))
(check-equal? (map view-action-kind ba2) '(scroll point))
(check-equal? (view-action-data (cadr ba2)) '(10 3 #t))
(define b3 (mouse b2 be 'release 10 3))
(define b4 (press b3 be (key 'backspace)))
;; 选区 (0,1) -> 最近可见末尾 (1,3)
(check-equal? (engine-view-text be 1) "ajkl")

;;; ---------- 拖到内容区上方：先向上滚，再落到可见起点 ----------
(define-values (u0 ue) (make-state "abcdef\nghijkl"))
(define u1 (mouse u0 ue 'press 1 2))
(define-values (u2 ua2) (mouse* u1 ue 'move -1 0))
(check-equal? (map view-action-kind ua2) '(scroll point))
(define u3 (mouse u2 ue 'release -1 0))
(define u4 (press u3 ue (key 'backspace)))
;; 选区 (1,2) -> 可见起点 (0,0)，反向也是同一个区间
(check-equal? (engine-view-text ue 1) "ijkl")

;;; ---------- 没有按下的 move：什么都不做 ----------
(define-values (n0 ne) (make-state "abc"))
(define-values (n1 na) (mouse* n0 ne 'move 0 2))
(check-equal? na '())
(check-false (app-state-select-drag n1))
(check-equal? (engine-view-text ne 1) "abc")

;;; ---------- 有边框：内容区相对坐标要减掉边框 ----------
(define-values (q0 qe) (make-state "abcdef\nghijkl" #:borders '(up down left right)))
(define-values (q1 qa1) (mouse* q0 qe 'press 2 2))   ; 绝对 -> 内容 (1,1)
(check-equal? (view-action-data (car qa1)) '(1 1 #f))
(define q2 (mouse q1 qe 'move 2 4))                  ; 绝对 -> 内容 (1,3)
(define q3 (mouse q2 qe 'release 2 4))
(define q4 (press q3 qe (key 'X)))
(check-equal? (engine-view-text qe 1) "abcdef\ngXjkl")

;;; ---------- 在边框上按下：只聚焦，不开始拖选 ----------
(define-values (w0 we) (make-state "abc" #:borders '(up down left right)))
(define-values (w1 wa1) (mouse* w0 we 'press 0 0))
(check-equal? wa1 '())
(check-false (app-state-select-drag w1))
(check-equal? (app-state-focus-panel-id w1) 'editor)

;;; ---------- 拖选后移动指针不切换焦点 / 不换 panel ----------
(define-values (f0 fe) (make-state "abcdef"))
(define f1 (mouse f0 fe 'press 0 1))
(define-values (f2 fa2) (mouse* f1 fe 'move 0 3))
(check-equal? (view-action-view-id (car fa2)) 1)
(check-equal? (app-state-focus-panel-id f2) 'editor)

(displayln "edit-tui-rebuild/test/mouse-select.rkt: ok")
