#lang racket

;;; edit-tui-rebuild/edit/commands.rkt —— 编辑 / 导航操作表
;;;
;;; 命令全部是 (state -> (values state actions))：
;;;   插入 / 删除 / 导航 / 翻页 / 撤销 -> view-action（runtime 解释）
;;;   不直接碰 engine。
;;;
;;; 两张表：
;;;   navigation-command-table  纯导航：方向 / Home / End / 翻页
;;;                             -> 焦点 panel 的 active view（任何面板都行，
;;;                                文件树也只是普通 buffer）
;;;   edit-command-table        = 导航表 + 插入 / 删除 / 撤销
;;;                             插入类只认 editor panel
;;;
;;; 可打印字符不占表项：命令表匹配不到时，app/step 调 edit-self-insert
;;; 兜底（见 model.rkt）。这样任意语言 / 任意字符都能输入，不用把
;;; Unicode 塞进表里。
;;;
;;; 绑定的 token 是 (tag . bytes)：终端不能区分的组合自然共用一个 token
;;; （C-i = Tab、C-m = Enter、C-[ = Escape …），不会出现“死绑定”。

(require "../skeleton.rkt"
         "../app/state.rkt"
         "insert.rkt")

(provide navigation-command-table
         edit-command-table
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
    [(not vid) (values (app-state-with-message state "edit: 焦点 panel 没有 view") '())]
    [else (values state (list (view-action kind vid data)))]))

;; 只作用于 editor 的命令（插入 / 删除 / 历史）
(define (emit-editor state kind data)
  (define vid (focus-editor-view state))
  (cond
    [(not vid) (values (app-state-with-message state "edit: 焦点不是 editor") '())]
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

;; ---------- 导航表 ----------

;; shift+方向 / shift+Home/End -> 扩展选区
(define (nav-binding dir)
  (list (list (list (key dir)) (nav-command dir))
        (list (list (key dir 'shift)) (nav-command dir #:extend? #t))))

(define navigation-command-table
  (command-table-from-bindings
   (append
    (append* (for/list ([d (in-list '(left right up down home end))])
               (nav-binding d)))
    ;; C-a / C-e 行首行尾，C-f / C-b 逐字符
    (list (list (list (key 'a 'ctrl)) (nav-command 'home))
          (list (list (key 'e 'ctrl)) (nav-command 'end))
          (list (list (key 'f 'ctrl)) (nav-command 'right))
          (list (list (key 'b 'ctrl)) (nav-command 'left)))
    ;; 翻页
    (list (list (list (key 'pageup))   (scroll-command 'page-up))
          (list (list (key 'pagedown)) (scroll-command 'page-down))))))

;; ---------- 编辑表 = 导航 + 编辑 ----------

(define edit-command-table
  (command-table-merge
   navigation-command-table
   (command-table-from-bindings
    (list
     ;; 插入 / 删除
     (list (list (key 'enter))     (insert-command "\n"))
     (list (list (key 'tab))       (insert-command "  "))
     (list (list (key 'backspace)) (edit-action-command 'backspace))
     (list (list (key 'delete))    (edit-action-command 'delete))
     (list (list (key 'd 'ctrl))   (edit-action-command 'delete))
     (list (list (key 'k 'ctrl))   (edit-action-command 'kill-line))
     ;; 历史
     (list (list (key 'z 'ctrl)) (edit-action-command 'undo))
     (list (list (key 'y 'ctrl)) (edit-action-command 'redo))))))
