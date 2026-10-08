#lang racket

;;; lab-rebuild/builtin/edit.rkt —— 基础编辑命令（功能包，只注册 command 贡献）。
;;;
;;; 命令只返回 effect；真正改 editor 在 pipeline.apply-effect。

(require "../kernel/api.rkt")

(provide register-edit!)

(define (focus-vid ctx) (session-focus-vid (ctx-session ctx)))

(define (event-text ev)
  (cond [(key-event? ev) (string (key-event-key ev))]
        [(paste-event? ev) (paste-event-text ev)]
        [else ""]))

(define (cmd-insert ctx ev)
  (define vid (focus-vid ctx))
  (define text (event-text ev))
  ;; 拦截型：任何 before-insert hook 先插手则它说了算（#f = 不插手）。
  (define handled (run-hooks-first ctx 'before-insert (list text)))
  (cond
    [(not handled) (if (and vid (positive? (string-length text)))
                       (list (e-type vid text 'lab-typing))
                       '())]
    [(null? handled) '()]                   ; 插手但不产 effect（如跳过）
    [else handled]))

(define (cmd-newline ctx ev)
  (define vid (focus-vid ctx))
  (if vid (list (e-type vid "\n" #f)) '()))

(define (cmd-tab ctx ev)
  (define vid (focus-vid ctx))
  (if vid (list (e-type vid "  " #f)) '()))

(define (cmd-backspace ctx ev)
  (define vid (focus-vid ctx))
  (if vid (list (e-backspace vid #f)) '()))

(define (cmd-delete ctx ev)
  (define vid (focus-vid ctx))
  (if vid (list (e-delete vid #f)) '()))

(define (cmd-nav ctx ev dir extend?)
  (define vid (focus-vid ctx))
  (if vid (list (e-nav vid dir extend?)) '()))

(define (cmd-undo ctx ev) (define v (focus-vid ctx)) (if v (list (e-undo v)) '()))
(define (cmd-redo ctx ev) (define v (focus-vid ctx)) (if v (list (e-redo v)) '()))
(define (cmd-select-all ctx ev) (define v (focus-vid ctx)) (if v (list (e-select-all v)) '()))
(define (cmd-copy ctx ev) (define v (focus-vid ctx)) (if v (list (e-copy v)) '()))
(define (cmd-cut ctx ev) (define v (focus-vid ctx)) (if v (list (e-cut v)) '()))
(define (cmd-paste ctx ev) (define v (focus-vid ctx)) (if v (list (e-paste v)) '()))
(define (cmd-quit ctx ev) (list e-quit))
(define (cmd-split ctx ev dir) (list (e-split dir)))
(define (cmd-pane-close ctx ev) (list e-pane-close))
(define (cmd-pane-swap ctx ev dir) (list (e-pane-swap dir)))
(define (cmd-pane-resize ctx ev dir) (list (e-pane-resize dir)))
(define (cmd-dock-cycle ctx ev side) (list (e-dock-cycle side)))
(define (cmd-focus-dir ctx ev dir) (list (e-focus-dir dir)))

(define commands
  (list (cons 'insert cmd-insert)
        (cons 'newline cmd-newline)
        (cons 'tab cmd-tab)
        (cons 'backspace cmd-backspace)
        (cons 'delete cmd-delete)
        (cons 'nav cmd-nav)
        (cons 'undo cmd-undo)
        (cons 'redo cmd-redo)
        (cons 'select-all cmd-select-all)
        (cons 'copy cmd-copy)
        (cons 'cut cmd-cut)
        (cons 'paste cmd-paste)
        (cons 'quit cmd-quit)
        (cons 'split-lr (λ (ctx ev) (cmd-split ctx ev 'lr)))
        (cons 'split-tb (λ (ctx ev) (cmd-split ctx ev 'tb)))
        (cons 'pane-close cmd-pane-close)
        (cons 'pane-swap cmd-pane-swap)
        (cons 'pane-resize cmd-pane-resize)
        (cons 'dock-cycle cmd-dock-cycle)
        (cons 'focus-dir cmd-focus-dir)))

(define (register-edit! r)
  (for/fold ([r r]) ([c (in-list commands)])
    (reg-add r (contrib 'command (car c) (cdr c)))))
