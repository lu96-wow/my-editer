#lang racket

;;; edit-rebuild/core/backend/tui.rkt —— racket-tui 输入 / 输出后端
;;;
;;; 输入：read-event → input（绑定键 + 载荷）→ dispatch → session
;;; 输出：session-render → pieces → format-* 字节
;;;
;;; 只有本模块碰终端 / FFI；session / layout / focus / command 保持纯。

(require tui
         "../command/dispatch.rkt"
         "../command/binding.rkt"
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/render.rkt"
         "../session/async.rkt"
         "../theme/theme.rkt"
         "../theme/style.rkt")

(provide draw! run-tui)

;;; ---------- 输入：事件 → input ----------

(define (event->input ev)
  (input (event->binding ev)
         (event-text ev)
         (and (resize-event? ev) (resize-event-cols ev))
         (and (resize-event? ev) (resize-event-rows ev))
         (and (mouse-event? ev) (mouse-col ev))
         (and (mouse-event? ev) (mouse-row ev))))

;;; ---------- 输出：piece → 字节 ----------

(define (rgb-fg c) (if c (format-rgb-fg-base (rgb-r c) (rgb-g c) (rgb-b c)) #""))
(define (rgb-bg c) (if c (format-rgb-bg-base (rgb-r c) (rgb-g c) (rgb-b c)) #""))

(define (attr-bytes a)
  (case a
    [(bold)      format-bold]
    [(dim)       format-dim]
    [(italic)    format-italic]
    [(underline) format-underline]
    [(blink)     format-blink]
    [(reverse)   format-reverse]
    [else #""]))

(define (style-bytes st)
  (bytes-append
   (rgb-fg (style-fg st))
   (rgb-bg (style-bg st))
   (for/fold ([b #""]) ([a (in-list (style-attrs st))])
     (bytes-append b (attr-bytes a)))))

(define (piece-style attr)
  (define t (current-theme))
  (style-bytes
   (cond
     [(pair? attr) (style-over (theme-style t (cdr attr)) (theme-overlay-style t (car attr)))]
     [else (theme-style t attr)])))

;;; ---------- 画一帧（增量） ----------

(define prev (box #f))
(define prev-size (box #f))

(define (draw! s)
  (define old (unbox prev))
  (define size (cons (session-width s) (session-height s)))
  (define fresh? (or (not old) (not (equal? size (unbox prev-size)))))
  (set-box! prev-size size)
  (define-values (s1 new rends sels) (session-render s old))
  (set-box! prev new)
  (put-bytes format-cursor-hide)
  (when fresh? (put-bytes format-screen-clear))
  (for ([p (in-list (append rends sels))])
    (put-bytes
     (bytes-append
      (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
      (piece-style (piece-attr p))
      (format-content (piece-text p))
      format-reset)))
  (flush!)
  s1)

;;; ---------- 主循环 ----------

(define (run-tui s0)
  (with-tui
   (lambda ()
     (define-values (rows cols) (get-window-size))
     (define s (session-resize s0 (or cols (session-width s0)) (or rows (session-height s0))))
     (set-box! prev #f)
     (set-box! prev-size #f)
     (define sbox (box s))
     (on-source async-wake (lambda (_) (set-box! sbox (draw! (unbox sbox)))))
     (let loop ()
       (define s1 (draw! (unbox sbox)))
       (set-box! sbox s1)
       (define ev (read-event))
       (define s2 (unbox sbox))
       (define s* (dispatch s2 (event->input ev)))
       (set-box! sbox s*)
       (unless (session-quit? s*) (loop))))))
