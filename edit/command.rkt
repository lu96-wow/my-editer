#lang racket

;;; edit/command.rkt —— 命令层：会话状态 + 纯命令转换
;;;
;;; document 是一等公民：
;;;     documents : (hash did -> doc-entry)
;;;     doc-entry = document + 该 document 自己的**键表**（命令挂在这里）
;;; view 只持 did；要文本的操作从 (session-doc s did) 取 document。
;;;
;;; session 只存真身；派生量（已放置 view / screen）每帧现算。
;;; 命令是纯转换：session × cmd -> session；副作用（读事件 / 写屏）在 edit/tui.rkt。

(require "area.rkt" "view.rkt" "layout.rkt" "focus.rkt" "keymap.rkt")

;;; ---------- 会话 ----------

;; 一个 document 的入口：内容 + 它自己的键表（打开时往里绑定）。
(struct doc-entry (document keys) #:transparent)

(struct session (documents next-did layout bindings focus width height quit? keys) #:transparent)
;; documents : (hash did -> doc-entry)
;; next-did  : nat
;; layout    : 布局定义树（leaf/slot/split/stack/at）
;; bindings  : slot-id -> node
;; focus     : focus
;; keys      : (listof keymap)  全局 / 框架键表叠

(provide (struct-out doc-entry)
         (struct-out session)
         session-doc session-doc-entry session-doc-of
         session-views session-screen
         session-view session-focus-vid session-focused-did session-set-focus
         session-update-view session-open-document session-doc-add-key
         (struct-out cmd-focus) (struct-out cmd-scroll) (struct-out cmd-toggle)
         (struct-out cmd-quit) (struct-out cmd-resize)
         step)

;;; ---------- document ----------

(define (session-doc-entry s did) (hash-ref (session-documents s) did))
(define (session-doc s did) (doc-entry-document (session-doc-entry s did)))
(define (session-doc-of s) (lambda (did) (session-doc s did)))

;; 开一个新 document（可同时给它的键表）。→ (values session did)
(define (session-open-document s doc [keys (kbd)])
  (define did (session-next-did s))
  (values (struct-copy session s
            [documents (hash-set (session-documents s) did (doc-entry doc keys))]
            [next-did (add1 did)])
          did))

;; 往某 document 的键表补一条绑定（打开时 / 运行时都行）。
(define (session-doc-add-key s did binding spec)
  (define e (session-doc-entry s did))
  (struct-copy session s
    [documents (hash-set (session-documents s) did
                         (struct-copy doc-entry e
                                      [keys (keymap-add (doc-entry-keys e) binding spec)]))]))

;;; ---------- 派生 ----------

(define (session-views s)
  (layout-place (session-layout s) (session-bindings s) (session-doc-of s)
                (area 0 0 (session-width s) (session-height s))))

(define (session-screen s)
  (compose (session-views s) (session-doc-of s) (session-focus-vid s)
           (session-width s) (session-height s)))

(define (session-focus-vid s) (focus-target (session-focus s)))

;; 已放置的 view 里按 vid 找。
(define (session-view s vid)
  (and vid (for/first ([v (in-list (session-views s))] #:when (eqv? vid (view-id v))) v)))

(define (session-focused-did s)
  (define v (session-view s (session-focus-vid s)))
  (and v (view-did v)))

(define (session-set-focus s f) (struct-copy session s [focus f]))

;; 就地改一个 view：layout 的叶 + bindings 的子树都覆盖。
(define (session-update-view s vid f)
  (define (upd v) (if (eqv? vid (view-id v)) (f v) v))
  (struct-copy session s
    [layout (layout-map-views (session-layout s) upd)]
    [bindings (for/hash ([(k n) (in-hash (session-bindings s))])
                (values k (layout-map-views n upd)))]))

;;; ---------- 命令 ----------

(struct cmd-focus (dir) #:transparent)     ; dir : 'left 'right 'up 'down
(struct cmd-scroll (n) #:transparent)      ; 滚焦点视图 n 个视觉行
(struct cmd-toggle (vid) #:transparent)    ; 切换某 view 显隐
(struct cmd-quit () #:transparent)
(struct cmd-resize (w h) #:transparent)

;;; ---------- 纯转换 ----------

(define (step s cmd)
  (cond
    [(cmd-focus? cmd)
     (session-set-focus s (focus-move (session-views s) (session-focus s) (cmd-focus-dir cmd)))]
    [(cmd-scroll? cmd)
     (define vid (session-focus-vid s))
     (if vid
         (session-update-view s vid
                              (lambda (v) (view-scroll v (session-doc s (view-did v))
                                                       (cmd-scroll-n cmd))))
         s)]
    [(cmd-toggle? cmd)
     (session-update-view s (cmd-toggle-vid cmd)
                          (lambda (v) (view-show v (not (view-visible? v)))))]
    [(cmd-resize? cmd)
     (struct-copy session s [width (cmd-resize-w cmd)] [height (cmd-resize-h cmd)])]
    [(cmd-quit? cmd) (struct-copy session s [quit? #t])]
    [else s]))
