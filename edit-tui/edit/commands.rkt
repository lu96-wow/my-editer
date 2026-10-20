#lang racket

;;; edit-tui-rebuild/edit/commands.rkt —— 编辑 / 导航命令
;;;
;;; 这里只定义命令，不定义键位；键位表在 config/keymap/。
;;; 命令全部是 (state -> (values state actions))：
;;;   插入 / 删除 / 导航 / 翻页 / 撤销 -> view-action（runtime 解释）
;;;   不直接碰 engine。
;;;
;;; 可打印字符不占表项：命令表匹配不到时，app/step 调 edit-self-insert
;;; 兜底（见 insert.rkt）。这样任意语言 / 任意字符都能输入，不用把
;;; Unicode 塞进表里。

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "insert.rkt")

(provide nav-command
         scroll-command
         insert-command
         edit-action-command
         edit-self-insert
         focus-editor-view)

;; 焦点 panel 是 editor -> 活动 view id；否则 #f（插入类命令只认 editor）。
(define (focus-editor-view state)
  (define p (app-state-focus-panel-resource state))
  (and p
       (eq? (panel-kind p) 'editor)
       (app-state-focus-view-id state)))

;; ---------- 命令构造 ----------

;; 通用 view 命令（导航 / 翻页）
(define (emit-view state kind data)
  (define vid (app-state-focus-view-id state))
  (cond
    [(not vid) (values (app-state-with-flash state "edit: 焦点 panel 没有 view") '())]
    [else (values state (list (view-action kind vid data)))]))

;; 只作用于 editor 的命令（插入 / 删除 / 历史）
(define (emit-editor state kind data)
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (app-state-with-flash state "edit: 焦点不是 editor") '())]
    [else (values state (list (view-action kind vid data)))]))

;; text : string（方便写键表）；action 里放 UTF-8 bytes，engine 解码一次。
(define (insert-command text)
  (λ (state) (emit-editor state 'insert (string->bytes/utf-8 text))))

(define (edit-action-command kind)
  (λ (state) (emit-editor state kind #f)))

;; dir : left | right | up | down | home | end
(define (nav-command dir #:extend? [extend? #f])
  (λ (state) (emit-view state 'nav (list dir extend?))))

;; which : 'page-up | 'page-down
(define (scroll-command which)
  (λ (state) (emit-view state 'scroll which)))

;; 命令表匹配不上时的兜底：可打印字符 -> 插入到焦点 editor view。
;; → (values state actions)；state = #f 表示「这个键不归编辑处理」。
(define (edit-self-insert state tok)
  (define bytes (self-insert-bytes tok))
  (define vid (and bytes
                   (not (app-state-placement state))
                   (null? (app-state-pending state))
                   (focus-editor-view state)))
  (cond
    [(not vid) (values #f '())]
    [else (values state (list (view-action 'insert vid bytes)))]))
