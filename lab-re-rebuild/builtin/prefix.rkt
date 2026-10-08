#lang racket

;;; lab-re-rebuild/builtin/prefix.rkt —— 前缀键（layer 栈）。
;;;
;;; 前缀 = 一个 layer：capture='all'（层表是唯一表）、pop='next'（按任意下一键退出）。
;;; 状态就是 label + 本层键表 + 字符表。键序列 = 嵌套 push（表里再给一个 prefix 命令）。
;;;
;;; ⚠ 普通字符事件统一绑定到 text-binding（见 kernel/binding.rkt），所以前缀里的
;;;   「单字符键」不能用 (key #\d) 表达；改用 chars: hash char -> command-spec，
;;;   由 cmd-prefix-char 按事件字符分派。

(require "../kernel/api.rkt")

(provide register-prefix! e-prefix (struct-out prefix) active-prefix-label)

(struct prefix (label tables chars) #:transparent)

(define (e-prefix label tables [chars (hash)])
  (e-layer-push 'prefix (prefix label tables chars)))

(define (prefix-state ctx)
  (define inst (stack-find (session-input (ctx-session ctx)) 'prefix))
  (and inst (layer-inst-state inst)))

(define prefix-layer
  (make-layer 'prefix
              #:tables (lambda (ctx inst)
                         (define p (layer-inst-state inst))
                         (cons (kbd text-binding 'prefix-char) (prefix-tables p)))
              #:capture 'all
              #:pop 'next))

(define (active-prefix-label ctx)
  (define p (prefix-state ctx))
  (and p (prefix-label p)))

;; 普通字符分派：查 chars 表，命中则调用对应命令。
(define (cmd-prefix-char ctx ev)
  (define p (prefix-state ctx))
  (cond
    [(not p) '()]
    [else
     (define ch (and (key-event? ev) (key-event-key ev) (char? (key-event-key ev))
                     (char-downcase (key-event-key ev))))
     (define spec (and ch (hash-ref (prefix-chars p) ch #f)))
     (if spec (invoke-command ctx spec ev) '())]))

(define focus-keys
  (kbd (key 'left)   '(focus-dir left)
       (key 'right)  '(focus-dir right)
       (key 'up)     '(focus-dir up)
       (key 'down)   '(focus-dir down)
       (key 'escape) 'noop))

;; C-p → 焦点方向；C-p d → 文档浮窗（show-docs 由 docs 特性注册）。
(define focus-chars (hash #\d 'show-docs))
(define (cmd-prefix-focus ctx ev)
  (list (e-prefix "C-p" (list focus-keys) focus-chars)))

(define move-keys
  (kbd (key 'left)   '(pane-swap left)
       (key 'right)  '(pane-swap right)
       (key 'up)     '(pane-swap up)
       (key 'down)   '(pane-swap down)
       (key 'escape) 'noop))
(define (cmd-prefix-move ctx ev)
  (list (e-prefix "M-m" (list move-keys))))

(define resize-keys
  (kbd (key 'left)   '(pane-resize left)
       (key 'right)  '(pane-resize right)
       (key 'up)     '(pane-resize up)
       (key 'down)   '(pane-resize down)
       (key 'escape) 'noop))
(define (cmd-prefix-resize ctx ev)
  (list (e-prefix "M-s" (list resize-keys))))

(define (register-prefix! r)
  (reg-add (reg-add (reg-add (reg-add (reg-add r (contrib 'layer-spec 'prefix prefix-layer))
                                      (contrib 'command 'prefix-focus cmd-prefix-focus))
                               (contrib 'command 'prefix-char cmd-prefix-char))
                    (contrib 'command 'prefix-move cmd-prefix-move))
           (contrib 'command 'prefix-resize cmd-prefix-resize)))
