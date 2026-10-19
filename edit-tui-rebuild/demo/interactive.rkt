#lang racket

;;; edit-tui-rebuild/demo/interactive.rkt —— 布局交互 demo
;;;
;;; 运行：
;;;   racket edit-tui-rebuild/demo/interactive.rkt
;;;
;;; 键：
;;;   C-w ←→↑↓      拆分当前 editor（空 panel）
;;;   C-b           显示 / 隐藏 filetree
;;;   M-←→↑↓        焦点在 panel 间移动
;;;   C-q           退出
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

(define (quit-command state)
  (values state (list (quit-action))))

(define command-table*
  (keys
   [(key 'w 'ctrl) (key 'left)  (split-command 'left)]
   [(key 'w 'ctrl) (key 'right) (split-command 'right)]
   [(key 'w 'ctrl) (key 'up)    (split-command 'up)]
   [(key 'w 'ctrl) (key 'down)  (split-command 'down)]
   [(key 'b 'ctrl)              (toggle-filetree-command)]
   [(key 'left 'alt)            (focus-command 'left)]
   [(key 'right 'alt)           (focus-command 'right)]
   [(key 'up 'alt)              (focus-command 'up)]
   [(key 'down 'alt)            (focus-command 'down)]
   [(key 'q 'ctrl)              quit-command]))

;;; ---------- resources / engine ----------

(define engine (make-engine))

(define-values (store1 a1)
  (resource-open resource-store-empty
                 #:name "editor"
                 #:text "hello, layout demo.\n\nC-w arrows split, C-b toggle filetree, M-arrows focus, C-q quit.\n"
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

;;; view ids: editor=1, filetree=2, state=3

;;; ---------- layout ----------

(define editor-panel
  (make-panel 'editor 'editor
              #:views '(1)
              #:active 1
              #:borders '(up down left right)))

(define filetree-panel
  (make-panel 'filetree 'sidebar
              #:views '(2)
              #:active 2
              #:borders '(right)))

(define state-panel
  (make-panel 'state 'status
              #:views '(3)
              #:active 3
              #:fixed-h 1))

(define l0 (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor editor-panel)
                        #:focus 'editor))
(define-values (l1 ok1?) (layout-panel-attach l0 'editor 'left filetree-panel #:ratio 3/8))
(define-values (l2 ok2?) (layout-panel-attach l1 'editor 'down state-panel))
(unless (and ok1? ok2?) (error 'demo "layout attach failed"))

(define demo-state
  (struct-copy app-state state1 [layout l2]))

(define demo-engine engine)

(module+ main
  (run-app demo-state demo-engine))
