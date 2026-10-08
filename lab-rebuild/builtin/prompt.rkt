#lang racket

;;; lab-rebuild/builtin/prompt.rkt —— 输入行（bottom dock 'input）。
;;;
;;; 独立 dock：label 作为只读前缀，用户输入在后；Enter 提交 / Escape 取消。
;;; 通过 **effect 'prompt** 暴露能力（kernel 留 tag，本模块注册 handler）；
;;; 调用方只发 `(e-prompt label on-submit)`，不 require 本模块。

(require "../kernel/api.rkt")

(provide register-prompt!)

(define (prompt-box ctx) (service-ref ctx 'prompt-box))
(define (prompt-init ctx) (service-put ctx 'prompt-box (box #f)))

(define (prompt-make root ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w 1 "*input*"))
  (values ed2 vid))

(define input-keys
  (kbd text-binding     'insert
       paste-binding    'insert
       (key 'enter)     'prompt-submit
       (key 'escape)    'prompt-cancel
       (key 'backspace) 'backspace
       (key 'delete)    'delete
       (key 'left)      '(nav left #f)
       (key 'right)     '(nav right #f)
       (key 'home)      '(nav home #f)
       (key 'end)       '(nav end #f)))

(define input-spec
  (dock-spec 'input 'bottom 1 #f prompt-make input-keys))

(define (input-vid ctx)
  (workspace-dock-vid (session-workspace (ctx-session ctx)) 'input))

;; label 作为只读前缀；光标落在末尾。
(define (input-doc label)
  (define doc (document-open label))
  (when (positive? (string-length label))
    (document-readonly-fill-batch doc (list (list 0 0 0 (string-length label) #t))))
  doc)

;; effect 'prompt 的处理器：设回调 + 显示 dock + 聚焦进去。
(define (apply-prompt ctx label on-submit)
  (set-box! (prompt-box ctx) (cons label on-submit))
  (define vid (input-vid ctx))
  (for/fold ([c ctx])
            ([e (in-list (list (e-reload vid (input-doc label))
                               (e-nav vid 'end #f)
                               (e-dock-visible 'input #t)
                               (e-focus-push vid)))])
    (apply-effect c e)))

(define (cmd-prompt-submit ctx ev)
  (define s (ctx-session ctx))
  (define vid (input-vid ctx))
  (define p (unbox (prompt-box ctx)))
  (define full (editor-view-string (session-editor s) vid))
  (define label (if p (car p) ""))
  (define text (substring full (min (string-length label) (string-length full)) (string-length full)))
  (set-box! (prompt-box ctx) #f)
  (append (list (e-dock-visible 'input #f) e-focus-restore)
          (if p ((cdr p) text) '())))

(define (cmd-prompt-cancel ctx ev)
  (set-box! (prompt-box ctx) #f)
  (list (e-dock-visible 'input #f) e-focus-restore))

(define (register-prompt! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'init 'prompt prompt-init)
                               (contrib 'dock 'input input-spec)
                               (contrib 'effect 'prompt apply-prompt)
                               (contrib 'command 'prompt-submit cmd-prompt-submit)
                               (contrib 'command 'prompt-cancel cmd-prompt-cancel)))])
    (reg-add r c)))
