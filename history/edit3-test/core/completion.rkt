#lang racket

;;; edit3-test/completion.rkt —— 补全（不抢焦点菜单 + 边打边筛 + 颜色）

(require rackunit racket/list
         "../../edit3/core/extension.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/adapter.rkt"
         "../../edit3/plugins/completion.rkt")

(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))

(define (start text)
  (define st (boot 80 24 #:name "*c*" #:text text #:plugins (list completion-spec)))
  (set-point! (state-ed st) (focused-vid st) 1 2)
  st)

(define (panel-of st)
  (define ed (state-ed st))
  (define cv (panel-vid st "*completion*"))
  (values ed cv (and cv (view-did ed cv))))

;; 打开：焦点留在编辑器（不抢），菜单浮窗存在
(define st0 (start "define something\nso"))
(define st1 (run1 st0 (key-event '/ '(alt))))
(check-true (and (feature-ref st1 'completion #f) #t))
(check-equal? (length (state-floats st1)) 1)
(check-equal? (state-focus st1) 0)                       ; 编辑器仍是焦点
;; 颜色：候选行写回，选中行 'complete-selected，其余 'complete
(define st1p (refresh-panels! st1))
(define-values (ed1 cv1 did1) (panel-of st1p))
(check-true (regexp-match? #rx"something" (view-string ed1 cv1)))
(check-eq? (document-face-at ed1 did1 0 3) 'complete-selected)

;; 位置：菜单在输入行的上方或下方（不盖住），且不超出编辑窗格
(define st1f (emit (refresh-panels! st1) 'before-render (list SZ)))
(define c-float (for/first ([fl (in-list (state-floats st1f))]
                            #:when (eqv? (panel-vid st1f "*completion*") (float-vid fl))) fl))
(define cgeo (layout (state-tiling st1f) (state-floats st1f) SZ))
(define c-tw (hash-ref (feature-ref st1f 'completion #f) 'target-w))
(define c-tv (hash-ref (feature-ref st1f 'completion #f) 'target-vid))
(define c-trect (placement-rect (for/first ([p (in-list (geometry-placements cgeo))]
                                             #:when (eqv? c-tw (placement-wid p))) p)))
(define c-mrect (placement-rect (for/first ([p (in-list (geometry-placements cgeo))]
                                             #:when (eqv? (float-wid c-float) (placement-wid p))) p)))
(define cpos (point->screen (state-ed st1f) c-tv (view-line (state-ed st1f) c-tv) (view-col (state-ed st1f) c-tv)))
(define c-row (+ (rect-y c-trect) (car cpos)))
(check-true (or (> (rect-y c-mrect) c-row)
                (<= (+ (rect-y c-mrect) (rect-h c-mrect)) c-row)))
(check-true (<= (+ (rect-x c-mrect) (rect-w c-mrect)) 80))

;; 边打边筛：菜单开着时打字进编辑器并重筛
(define st2 (run1 st1 (text-event "z")))                  ; 前缀 "soz" -> 无候选 -> 关
(check-false (feature-ref st2 'completion #f))
(define st3 (start "foobar foobaz\nf"))
(define st4 (run1 st3 (key-event '/ '(alt))))
(check-true (and (feature-ref st4 'completion #f) #t))
(define st5 (run1 st4 (text-event "o")))                  ; "fo"
(check-true (and (member "foobar" (hash-ref (feature-ref st5 'completion #f) 'candidates)) #t))
(define st6 (run1 st5 (text-event "o")))                  ; "foo"
(check-equal? (hash-ref (feature-ref st6 'completion #f) 'candidates)
              '("foobar" "foobaz"))
(define st7 (run1 st6 (key-event 'enter '())))            ; 接受 foobar
(check-equal? (view-string (state-ed st7) (focused-vid st7)) "foobar foobaz\nfoobar")
(check-equal? (length (state-floats st7)) 0)

;; Up/Down：有菜单移候选（光标不动），无菜单回落导航
(define stm0 (start "foobar foobaz\nfo"))
(define stm1 (run1 stm0 (key-event '/ '(alt))))
(check-equal? (hash-ref (feature-ref stm1 'completion #f) 'index) 0)
(define stm2 (run1 stm1 (key-event 'down '())))
(check-equal? (hash-ref (feature-ref stm2 'completion #f) 'index) 1)
(check-equal? (view-line (state-ed stm2) (focused-vid stm2)) 1)   ; 光标没动
(define stm3 (run1 stm2 (key-event 'enter '())))
(check-equal? (view-string (state-ed stm3) (focused-vid stm3)) "foobar foobaz\nfoobaz")
;; 无菜单：Down 回落普通导航
(define nav0 (start "a\nb\nc"))
(check-equal? (view-line (state-ed nav0) (focused-vid nav0)) 1)
(define nav1 (run1 nav0 (key-event 'down '())))
(check-equal? (view-line (state-ed nav1) (focused-vid nav1)) 2)

;; 取消：不改文本，菜单关
(define stc0 (start "define something\nso"))
(define stc1 (run1 stc0 (key-event '/ '(alt))))
(define stc2 (run1 stc1 (key-event 'escape '())))
(check-equal? (length (state-floats stc2)) 0)
(check-false (feature-ref stc2 'completion #f))
(check-equal? (view-string (state-ed stc2) (focused-vid stc2)) "define something\nso")

(displayln "edit3/completion.rkt: all tests passed")
