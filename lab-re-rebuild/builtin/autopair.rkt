#lang racket

;;; lab-re-rebuild/builtin/autopair.rkt —— 自动配对（输入插件，走 before-insert）。
;;;
;;; 输入开括号 ( [ { → 自动补闭括号、光标停中间；
;;; 输入闭括号且右边就是同一个 → 跳过（右移）。
;;; 返回 effects（#f = 不插手，默认插入）。
;;;
;;; 只在主区编辑视图生效（焦点在 dock / prompt 时不插手）。

(require "../kernel/api.rkt")

(provide register-autopair! auto-pair-effects)

(define open->close (hash #\( #\) #\[ #\] #\{ #\} #\< #\>))
(define closer? (hash #\) #t #\] #t #\} #t #\> #t))

(define (auto-pair-effects ctx args)
  (define text (car args))
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (define ed (session-editor s))
  (cond
    [(or (not vid) (not (= 1 (string-length text)))) #f]
    [(not (main-view? s vid)) #f]
    [(not (selection-empty? (editor-view-primary ed vid))) #f]
    [else
     (define ch (string-ref text 0))
     (define line (editor-view-point-line ed vid))
     (define col (editor-view-point-column ed vid))
     (cond
       [(hash-has-key? open->close ch)
        (if (editor-view-editable? ed vid line col line col)
            (list (e-type vid (string ch (hash-ref open->close ch)) #f)
                  (e-nav vid 'left #f))
            #f)]
       [(and (hash-has-key? closer? ch)
             (eqv? ch (editor-view-char-at ed vid line col)))
        (list (e-nav vid 'right #f))]
       [else #f])]))

(define (register-autopair! r)
  (reg-add r (contrib 'hook 'autopair (make-hook 'before-insert auto-pair-effects))))
