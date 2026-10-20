#lang racket

;;; edit-tui-rebuild/demo/interactive.rkt —— 布局交互 demo
;;;
;;; 运行：
;;;   racket edit-tui-rebuild/demo/interactive.rkt
;;;
;;; 键：
;;;   C-w ←→↑↓      拆分当前 editor（空 panel）
;;;   C-b           显示 / 隐藏 filetree
;;;   C-x ←→↑↓      焦点在 panel 间移动
;;;   C-s           保存当前 resource（无 path -> 输入栏 Save as）
;;;   C-i           插入 x（制造 dirty）
;;;   C-q           退出（dirty -> 输入栏确认）
;;;
;;; 鼠标：
;;;   拖 panel 接缝  resize
;;;   点 panel      聚焦

(require "../config/theme/default.rkt"
         "../main.rkt")

(provide demo-state demo-engine)

(define (notice state text)
  (struct-copy app-state state [message text]))

(define (focus-resource-of state id)
  (define p (layout-panel (app-state-layout state) id))
  (define vid (and p (panel-view p)))
  (and vid (resource-of-view (app-state-resources state) vid)))

(define (set-focus-panel state id)
  (define layout* (layout-set-focus (app-state-layout state) id))
  (define s1 (struct-copy app-state state [layout layout*]))
  (struct-copy app-state s1 [focus-resource (focus-resource-of s1 id)]))

(define (sync-focus-resource state)
  (struct-copy app-state state
               [focus-resource
                (focus-resource-of state (layout-focus (app-state-layout state)))]))

;;; ---------- commands ----------

(define (split-command dir)
  (λ (state)
    (define l (app-state-layout state))
    (define pid (layout-focus l))
    (define nid (app-state-next-panel-id state))
    (define-values (l* ok?)
      (layout-split l pid dir nid #:config default-config))
    (if ok?
        (values (struct-copy app-state state
                             [layout l*]
                             [next-panel-id (add1 nid)])
                '())
        (values (notice state "split failed") '()))))

(define (toggle-filetree-command)
  (λ (state)
    (define l (app-state-layout state))
    (define area (app-state-area state))
    (define visible? (layout-panel-visible? l 'filetree))
    (define-values (l* ok?)
      (if visible?
          (layout-panel-hide l area 'filetree #:config default-config)
          (layout-panel-show l area 'filetree)))
    (if ok?
        (values (sync-focus-resource
                 (struct-copy app-state state [layout l*]))
                '())
        (values (notice state "toggle filetree failed") '()))))

(define (focus-command dir)
  (λ (state)
    (define l (app-state-layout state))
    (define from (layout-focus l))
    (define to (layout-focus-neighbor l (app-state-area state)
                                      default-config from dir))
    (if to
        (values (set-focus-panel state to) '())
        (values (notice state "no focus neighbor") '()))))

(define (save-command state)
  (define rid (app-state-focus-resource state))
  (cond
    [(not rid) (values (notice state "save: no resource") '())]
    [else
     (define-values (store* actions)
       (resource-save (app-state-resources state) rid))
     (values (struct-copy app-state state [resources store*]) actions)]))

(define (insert-x-command state)
  (define rid (app-state-focus-resource state))
  (define vid (and rid (first (resource-view-ids (app-state-resources state) rid))))
  (if vid
      (values state (list (view-action 'insert vid "x")))
      (values (notice state "insert: no focused resource") '())))

(define (quit-command state)
  (define-values (store* actions)
    (resource-request-quit (app-state-resources state)))
  (values (struct-copy app-state state [resources store*]) actions))

(define command-table*
  (keys
   [(key 'w 'ctrl) (key 'left)  (split-command 'left)]
   [(key 'w 'ctrl) (key 'right) (split-command 'right)]
   [(key 'w 'ctrl) (key 'up)    (split-command 'up)]
   [(key 'w 'ctrl) (key 'down)  (split-command 'down)]
   [(key 'b 'ctrl)              (toggle-filetree-command)]
   [(key 'x 'ctrl) (key 'left)  (focus-command 'left)]
   [(key 'x 'ctrl) (key 'right) (focus-command 'right)]
   [(key 'x 'ctrl) (key 'up)    (focus-command 'up)]
   [(key 'x 'ctrl) (key 'down)  (focus-command 'down)]
   [(key 's 'ctrl)              save-command]
   [(key 'i 'ctrl)              insert-x-command]
   [(key 'q 'ctrl)              quit-command]))

;;; ---------- resources / engine ----------

(define engine (make-engine))

(define-values (store1 a1)
  (resource-open resource-store-empty
                 #:name "editor"
                 #:text "hello, layout demo.\n\nC-w arrows split, C-b toggle filetree, C-x arrows focus, C-q quit.\n"
                 #:tables (list command-table*)))

(define-values (store2 a2)
  (resource-open store1
                 #:name "filetree"
                 #:text "workspace\n  src\n  main.rkt"))

(define-values (store3 a3)
  (resource-open store2
                 #:name "state"
                 #:text "state focus=editor msg=ready"))

(define state0
  (make-app-state #:resources store3
                  #:focus-resource 1
                  #:overlays (list command-table*)
                  #:area (rect 0 0 80 24)
                  #:next-panel-id 100))

(define state1 (run-actions state0 engine (append a1 a2 a3)))

;;; filetree 自己的 core view：doc=10, view=10
(void (engine-create-buffer! engine 10 "*filetree*" ""))
(void (engine-create-view! engine 10 10))
(void (engine-create-buffer! engine 20 "*status*" ""))
(void (engine-create-view! engine 20 20))
(void (engine-create-buffer! engine 21 "*input*" ""))
(void (engine-create-view! engine 21 21))

(define state2
  (filetree-install-state state1 10 (current-directory)))
(define state3 (status-install-state state2 20))
(define state4 (input-install-state state3 'status 20 21))

;;; view ids: editor=1, state=3, filetree=10

;;; ---------- layout ----------

(define editor-panel
  (make-panel 'editor 'editor
              #:views '(1)
              #:active 1
              #:borders '(up down left right)))

(define filetree-panel
  (make-panel 'filetree 'sidebar
              #:views '(10)
              #:active 10
              #:borders '(right)))

(define status-panel
  (make-panel 'status 'status
              #:views '(20 21)
              #:active 20
              #:fixed-h 1))

(define l0 (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor editor-panel)
                        #:focus 'editor))
(define-values (l1 ok1?) (layout-panel-attach l0 'editor 'left filetree-panel #:ratio 3/8))
(define-values (l2 ok2?) (layout-panel-attach l1 'editor 'down status-panel))
(unless (and ok1? ok2?) (error 'demo "layout attach failed"))

(define demo-state
  (struct-copy app-state state4 [layout l2]))

(define demo-engine engine)

(module+ main
  (run-app demo-state demo-engine))
