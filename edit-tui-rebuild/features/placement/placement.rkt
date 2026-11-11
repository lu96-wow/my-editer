#lang racket

;;; edit-tui-rebuild/editor/placement.rkt —— 把 view 放进目标 editor panel
;;;
;;; 旧行为：
;;;   打开新文件 / 已打开但 detached 的 view -> placement
;;;   ↑←→↓ 在 editor panel 之间移动焦点
;;;   Enter 放入当前焦点 editor
;;;   鼠标点 editor 也可放入
;;;   Esc 取消
;;;
;;; placement 是 State 上的一个临时模式；host 在 placement 激活时只用
;;; placement-command-table，不混入全局插件命令。

(require "../../core/command/api.rkt"
         "../../core/layout/api.rkt"
         "../../core/focus/api.rkt"
         "../../core/projection/api.rkt"
         (prefix-in p: "../../core/panel/api.rkt")
         "../../editor/api.rkt"
         "../../editor/state.rkt")

(provide editor-placement-active?
         editor-placement-view-id
         editor-placement-start
         editor-placement-cancel
         editor-placement-commit
         editor-placement-focus!
         editor-placement-mouse!
         editor-place-into-panel!
         placement-command-table)

(define (editor-placement-active? state)
  (and (editor-state-placement state) #t))

(define (editor-placement-view-id state)
  (editor-state-placement state))

(define (first-editor-panel state)
  (for/first ([pid (in-list (or (editor-visible-editor-panels state) '()))])
    pid))

(define (focus-first-editor state)
  (define pid (first-editor-panel state))
  (cond
    [(not pid) state]
    [else
     (struct-copy editor-state state
                  [layout (layout-set-focus (editor-state-layout state) pid)])]))

;; 开始 placement：view-id 已经在 engine 里，但还没挂到 panel。
(define (editor-placement-start state vid)
  (define state1
    (struct-copy editor-state state
                 [placement vid]
                 [pending '()]))
  (if (eq? (editor-focus-panel-kind state1) 'editor)
      state1
      (focus-first-editor state1)))

(define (editor-placement-cancel ed state)
  (values (struct-copy editor-state state
                       [placement #f]
                       [flash "placement cancelled"])
          '()))

;; 把 view 加入目标 panel，并让该 view 成为 active。
(define (editor-place-into-panel! ed state pid vid)
  (define l (editor-state-layout state))
  (define-values (l* ok?) (layout-panel-add-view l pid vid))
  (cond
    [(not ok?)
     (values (editor-state-with-flash state "place: target panel missing") #f)]
    [else
     (define l** (layout-set-focus l* pid))
     (values (struct-copy editor-state state
                          [layout l**]
                          [placement #f]
                          [flash "view placed"])
             #t)]))

(define (target-editor-panel state)
  (define focus (editor-focus-panel state))
  (cond
    [(and focus (eq? (p:panel-kind focus) 'editor)) (p:panel-id focus)]
    [else (first-editor-panel state)]))

(define (editor-placement-commit ed state)
  (define vid (editor-placement-view-id state))
  (define pid (target-editor-panel state))
  (cond
    [(not vid) (values state '())]
    [(not pid) (values (editor-state-with-flash state "place: no editor panel") '())]
    [else
     (define-values (state* ok?) (editor-place-into-panel! ed state pid vid))
     (values state* '())]))

(define (next-editor-in-direction state from dir)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (let loop ([at from] [seen '()])
    (define next (and l area
                      (layout-focus-neighbor l area (editor-state-layout-config state) at dir)))
    (cond
      [(not next) #f]
      [(memv next seen) #f]
      [(eq? (p:panel-kind (layout-panel l next)) 'editor) next]
      [else (loop next (cons next seen))])))

(define (editor-placement-focus! ed state dir)
  (define from (editor-focus-panel-id state))
  (define to (next-editor-in-direction state from dir))
  (cond
    [to (values (struct-copy editor-state state
                             [layout (layout-set-focus (editor-state-layout state) to)])
                '())]
    [else (values (editor-state-with-flash state (format "place: no editor to the ~a" dir))
                  '())]))

;; 鼠标：placement 中点到 editor panel 就放入；返回 handled?。
(define (editor-placement-mouse! ed state row col)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (cond
    [(or (not l) (not area)) (values state '() #f)]
    [else
     (define h (layout-hit l area row col))
     (define pid (hit-panel-id h))
     (define p (and pid (layout-panel l pid)))
     (cond
       [(and p (eq? (p:panel-kind p) 'editor) (editor-placement-view-id state))
        (define-values (state* ok?)
          (editor-place-into-panel! ed state pid (editor-placement-view-id state)))
        (values state* '() ok?)]
       [else (values state '() #f)])]))

(define (placement-command dir)
  (λ (ed state) (editor-placement-focus! ed state dir)))

(define placement-command-table
  (keys
   [(key 'enter)  (λ (ed state) (editor-placement-commit ed state))]
   [(key 'escape) (λ (ed state) (editor-placement-cancel ed state))]
   [(key 'left)   (placement-command 'left)]
   [(key 'right)  (placement-command 'right)]
   [(key 'up)     (placement-command 'up)]
   [(key 'down)   (placement-command 'down)]))
