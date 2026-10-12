#lang racket

;;; edit4-test/runtime.rkt —— 运行时回路（脚本化后端，不碰终端）

(require rackunit
         racket/list racket/file
         "../edit4/layout.rkt"
         "../edit4/runtime.rkt"
         "../edit4/app.rkt"
         "../edit4/core/event.rkt"
         "../edit4/core/effect.rkt"
         "../edit4/core/command.rkt"
         "../edit4/core/keymap.rkt"
         "../edit4/core/world.rkt"
         (only-in "../edit4/content/engine.rkt" piece-text view-string)
         "../edit4/content/content.rkt")

(define SZ (cons 60 10))

(define (scripted-backend evs)
  (define q (box evs))
  (define drawn (box '()))
  (values
   (backend
    (lambda () SZ)
    (lambda ()
      (define l (unbox q))
      (cond [(null? l) (key-event 'q '(ctrl))]
            [else (set-box! q (cdr l)) (car l)]))
    (lambda (ps) (set-box! drawn ps))
    void)
   drawn))

;;; ---------- 打字 → 渲染 → 退出 ----------

(define-values (b1 drawn1) (scripted-backend (list (text-event "hi") (key-event 'q '(ctrl)))))
(define wend (run b1 (app-commands) (app-scopes) (app-keymap) (app-panels) (boot)))
(define cend (world-content wend))
(check-equal? (view-string (content-ed cend) (content-vid-of cend 0)) "hi")
(check-true (for/or ([p (in-list (unbox drawn1))]) (regexp-match? #rx"h" (piece-text p))))

;;; ---------- 分裂 → 两窗 → 关闭 ----------

(define-values (b2 _drawn2)
  (scripted-backend (list (key-event 's '(ctrl)) (key-event 'right '())
                          (key-event 'd '(ctrl)) (key-event 'q '(ctrl)))))
(define w2 (run b2 (app-commands) (app-scopes) (app-keymap) (app-panels) (boot)))
(check-equal? (length (ids (world-layout w2))) 3)   ; 分裂后关闭，回到三窗底盘

;;; ---------- open-file effect → 新文档绑定到焦点窗 ----------

(define tmpf (make-temporary-file "ed4rt~a"))
(display-to-file "FILE-CONTENT" tmpf #:exists 'truncate)

(define (h-open-test ctx w args) (cons w (list (open-file tmpf))))
(define reg* (command-register (app-commands) 'open-test h-open-test))
(define km* (compose-keymaps (list (app-keymap)
                                   (list (list '(key o ctrl) 'always (cmd 'open-test))))))
(define-values (b3 _drawn3) (scripted-backend (list (key-event 'o '(ctrl)) (key-event 'q '(ctrl)))))
(define w3 (run b3 reg* (app-scopes) km* (app-panels) (boot)))
(check-equal? (view-string (content-ed (world-content w3)) (content-vid-of (world-content w3) 0))
              "FILE-CONTENT")

(displayln "edit4/runtime.rkt: all tests passed")
