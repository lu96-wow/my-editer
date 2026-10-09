#lang racket

;;; edit/feature/log.rkt —— 只读日志窗口（底部，与 status / input 同位置互斥）
;;;
;;; 内容来自 (session-log s)：每行一条。错误等由 session-log! 追加并弹出。
;;; Esc 关闭（session-log-close）。rows=3：显示时底部区自动变高。

(require "api.rkt")

(provide log-install (struct-out cmd-log-close))

(struct cmd-log-close () #:transparent)

(define (log-document lines)
  (panel-doc
   (for/list ([l (in-list lines)])
     (list l 'log))))

(define (make-refresh)
  (define last (box #f))
  (lambda (s)
    (define lines (session-log s))
    (cond [(equal? lines (unbox last)) #f]
          [else (set-box! last lines) (log-document lines)])))

(define log-keys
  (kbd
   (key 'escape) (cmd-log-close)
   (key 'up)     (cmd-nav 'up #f)
   (key 'down)   (cmd-nav 'down #f)
   (key 'home)   (cmd-nav 'home #f)
   (key 'end)    (cmd-nav 'end #f)))

(define (log-handler vid)
  (lambda (s cmd)
    (cond
      ;; Esc：仅在 log 聚焦时关闭
      [(cmd-log-close? cmd) (and (eqv? vid (session-focus-vid s)) (session-log-close s))]
      ;; 主动开关：任意焦点下都能开/关
      [(cmd-log-toggle? cmd) (session-log-toggle s)]
      [else #f])))

;; → (values session vid)
(define (log-install s width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*log*"))
  (define p (panel 'log vid (make-refresh) log-keys 'bottom 3))
  (values (session-add-handler
           (session-set-visible (session-add-panel s1 p) vid #f)
           (log-handler vid))
          vid))
