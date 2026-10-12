#lang racket

;;; edit4-test/runtime.rkt —— 运行时回路（脚本化后端，不碰终端）

(require rackunit
         racket/list racket/file
         "../edit4/layout.rkt"
         "../edit4/runtime.rkt"
         "../edit4/app.rkt"
         "../edit4/boot.rkt"
         "../edit4/env.rkt"
         "../edit4/core/event.rkt"
         "../edit4/core/effect.rkt"
         "../edit4/core/command.rkt"
         "../edit4/core/keymap.rkt"
         "../edit4/core/world.rkt"
         (only-in "../edit4/content/adapter.rkt" piece-text view-string)
         "../edit4/content/model.rkt")

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

;;; ---------- 打字 → 退出（脏文档 → 先问保存） ----------

(define-values (b1 drawn1)
  (scripted-backend (list (text-event "hi")
                          (key-event 'q '(ctrl)) (text-event "n") (key-event 'enter '()))))
(define wend (run b1 (app-environment) (boot #:name "*scratch*")))
(define cend (world-content wend))
(check-equal? (view-string (content-ed cend) (content-vid-of cend 0)) "hi")
(check-true (for/or ([p (in-list (unbox drawn1))]) (regexp-match? #rx"h" (piece-text p))))

;;; ---------- 分裂 → 两窗 → 关闭 ----------

(define-values (b2 _drawn2)
  (scripted-backend (list (key-event 's '(ctrl)) (key-event 'right '())
                          (key-event 'd '(ctrl)) (key-event 'q '(ctrl)))))
(define w2 (run b2 (app-environment) (boot #:name "*scratch*")))
(check-equal? (length (ids (world-layout w2))) 3)   ; 分裂后关闭，回到三窗底盘

;;; ---------- open-file effect → 新文档绑定到焦点窗 ----------

(define tmpf (make-temporary-file "ed4rt~a"))
(display-to-file "FILE-CONTENT" tmpf #:exists 'truncate)

(define (h-open-test ctx w args) (cons w (list (open-file tmpf))))
(define env0 (app-environment))
(define env*
  (struct-copy environment env0
               [commands (command-register (environment-commands env0) 'open-test h-open-test)]
               [keymap (compose-keymaps (list (environment-keymap env0)
                                              (list (list '(key o ctrl) 'always (cmd 'open-test)))))]))
(define-values (b3 _drawn3)
  (scripted-backend (list (key-event 'o '(ctrl)) (key-event 'o '(ctrl)) (key-event 'q '(ctrl)))))
(define w3 (run b3 env* (boot #:name "*scratch*")))
(check-equal? (view-string (content-ed (world-content w3)) (content-vid-of (world-content w3) 0))
              "FILE-CONTENT")
;; 第二次 open 同一路径 → 复用，不重复建文档
(check-equal? (length (content-doc-paths (world-content w3))) 1)

;;; ---------- 多窗口 open → placing：Enter 放目标窗 ----------

;; 分裂成两窗（C-s →），open → 进 placing，Enter 确认放到焦点窗。
(define-values (b5 _drawn5)
  (scripted-backend (list (key-event 's '(ctrl)) (key-event 'right '())
                          (key-event 'o '(ctrl))
                          (key-event 'enter '())
                          (key-event 'q '(ctrl)))))
(define w5 (run b5 env* (boot)))
(check-equal? (view-string (content-ed (world-content w5))
                           (content-vid-of (world-content w5) (world-focus w5)))
              "FILE-CONTENT")
(check-true (not (content-placing (world-content w5))))   ; 确认后退出 placing

;;; ---------- log-effect → 写进日志面板缓冲 ----------

(require "../edit4/core/effect.rkt")
(define (h-log-test ctx w args) (cons w (list (log-effect "hello-log"))))
(define env-log
  (struct-copy environment env0
               [commands (command-register (environment-commands env0) 'log-test h-log-test)]
               [keymap (compose-keymaps (list (environment-keymap env0)
                                              (list (list '(key g ctrl) 'always (cmd 'log-test)))))]))
(define-values (b4 _d4) (scripted-backend (list (key-event 'g '(ctrl)) (key-event 'q '(ctrl)))))
(define w4 (run b4 env-log (boot #:name "*scratch*")))
(check-not-false (member "hello-log" (content-log (world-content w4))))

(displayln "edit4/runtime.rkt: all tests passed")
