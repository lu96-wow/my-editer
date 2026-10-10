#lang racket

;;; edit-rebuild/plugins/ui/log.rkt —— 日志窗口插件（停靠面，与 status / input 同区域互斥）
;;;
;;; 内容来自 (session-log s)。内核 session-log! 只追加并发 'log-appended；本插件订阅
;;; 该通知，在没有输入行时把自己弹出来。Esc 关闭，C-l 开关。

(require "../../core/extension/api.rkt"
         "../../core/extension/spec.rkt"
         "../../core/focus.rkt"
         "ids.rkt")

(provide log-spec (struct-out cmd-log-close))

(struct cmd-log-close () #:transparent)

(define (log-document lines)
  (panel-doc (for/list ([l (in-list lines)]) (list l 'log))))

(define (make-content)
  (define last (box #f))
  (lambda (s)
    (define lines (session-log s))
    (cond
      [(equal? lines (unbox last)) #f]
      [else (set-box! last lines) (log-document lines)])))

(define log-keys
  (kbd
   (key 'escape) (cmd-log-close)
   (key 'up)     (cmd-nav 'up #f)
   (key 'down)   (cmd-nav 'down #f)
   (key 'home)   (cmd-nav 'home #f)
   (key 'end)    (cmd-nav 'end #f)))

;; 刷新后把 log 光标移到最后一行。
(define (log-goto-end! s)
  (define vid (session-panel-vid s panel-log))
  (cond
    [(not vid) s]
    [else
     (session-refresh s)
     (define n (length (session-log s)))
     (if (zero? n) s (session-ed-set-point! s vid (sub1 n) 0))]))

(define (log-open s) (log-goto-end! (session-bottom-pop s panel-log)))

(define (log-close s)
  (define s1 (session-region-select s slot-bottom panel-status))
  (session-set-focus s1 (focus-restore (session-focus s1))))

(define (log-toggle s)
  (define vid (session-panel-vid s panel-log))
  (if (and vid (session-visible? s vid)) (log-close s) (log-open s)))

(define (log-handler vid)
  (lambda (s cmd)
    (cond
      [(cmd-log-close? cmd) (and (eqv? vid (session-focus-vid s)) (log-close s))]
      [(cmd-log-toggle? cmd) (log-toggle s)]
      [else #f])))

;; 内核追加日志 → 没在输入时弹日志窗。
(define (log-appended-hook s _args)
  (cond [(session-prompt s) s]
        [else (log-open s)]))

(define (log-install s)
  (define-values (s1 _did vid)
    (session-add-document s "" (session-width s) 3 #:name "*log*"))
  (define sf (dock-surface panel-log vid (make-content) log-keys slot-bottom 'height 3))
  (define s2 (session-set-visible (session-add-surface s1 sf) vid #f))
  (define s3 (session-add-handler s2 (log-handler vid)))
  (define s4 (session-add-hook s3 (hook 'log-appended log-appended-hook)))
  (session-add-key s4 (kbd (key 'l 'ctrl) (cmd-log-toggle))))

(define log-spec (plugin-spec 'log log-install '()))
