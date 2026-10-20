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
;;;   C-q           退出（dirty -> 输入栏确认）
;;;
;;; 编辑（edit/commands.rkt 的编辑操作表）：
;;;   直接打字      插入（任意可打印字符，含大写 / 中文）
;;;   Enter         换行
;;;   Tab           插入两个空格
;;;   Backspace     删前一个字符      Delete / C-d  删后一个字符
;;;   ←→↑↓ / Home / End  移动             Shift+方向  扩展选区
;;;   C-a / C-e     行首 / 行尾
;;;   PageUp/Down   翻页              C-k  删到行尾
;;;   C-z / C-y     撤销 / 重做
;;;   （C-i 与 Tab 是同一个字节，所以绑 Tab 就能收到 C-i）
;;;
;;; 输入栏（Save as / 退出确认）：
;;;   ←→ Home End / Backspace / Delete 编辑，C-h / C-t 行首 / 行尾；粘贴可用；
;;;   Enter 提交，Esc / C-g 取消；
;;;   confirm 提示里有文件路径，可输 y / n / all / nall。
;;;
;;; 鼠标：
;;;   拖 panel 接缝  resize
;;;   点 panel      聚焦（焦点窗口边框用 focused-border 高亮）
;;;   点 buffer 内容 把主光标放到点击处（filetree 也只是普通 buffer）
;;;
;;; 文件树 / placement：
;;;   filetree 就是普通 buffer：←→↑↓ / Home End 自由移动光标（列不钉死在行首），
;;;   PageUp/Down 滚一屏；Enter 展开目录 / 打开文件（已打开则聚焦 / 进入 placement）
;;;   placement 中：↑←→↓ 在 editor 间改焦点，Enter 放入，Esc 取消，
;;;     鼠标点目标 editor 也可（放完临时表自动解除）

(require "../config/theme/default.rkt"
         "../main.rkt")

(provide demo-state demo-engine)

;;; ---------- commands ----------

(define (split-command dir)
  (λ (state)
    (define layout (app-state-layout state))
    (define pid (app-state-focus-panel-id state))
    (define nid (app-state-next-panel-id state))
    (define-values (layout* ok?)
      (layout-split layout pid dir nid #:config default-config))
    (if ok?
        (values (app-state-refresh-focus-resource
                 (struct-copy app-state state
                              [layout layout*]
                              [next-panel-id (add1 nid)]))
                '())
        (values (app-state-with-message state "split failed") '()))))

(define (toggle-filetree-command)
  (λ (state)
    (define layout (app-state-layout state))
    (define area (app-state-area state))
    (define visible? (layout-panel-visible? layout 'filetree))
    (define-values (layout* ok?)
      (if visible?
          (layout-panel-hide layout area 'filetree #:config default-config)
          (layout-panel-show layout area 'filetree)))
    (if ok?
        ;; 隐藏可能导致焦点回退：按新 layout 的焦点重算 focus-resource
        (values (app-state-refresh-focus-resource
                 (struct-copy app-state state [layout layout*]))
                '())
        (values (app-state-with-message state "toggle filetree failed") '()))))

(define (focus-command dir)
  (λ (state)
    (define layout (app-state-layout state))
    (define to (layout-focus-neighbor layout (app-state-area state)
                                      default-config
                                      (app-state-focus-panel-id state) dir))
    (if to
        (values (app-state-set-focus-panel state to) '())
        (values (app-state-with-message state "no focus neighbor") '()))))

(define (save-command state)
  (define rid (app-state-focus-resource state))
  (cond
    [(not rid) (values (app-state-with-message state "save: no resource") '())]
    [else
     (define-values (store* actions)
       (resource-save (app-state-resources state) rid))
     (values (struct-copy app-state state [resources store*]) actions)]))

(define (quit-command state)
  (define-values (store* actions)
    (resource-request-quit (app-state-resources state)))
  (values (struct-copy app-state state [resources store*]) actions))

(define global-command-table
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
   [(key 'q 'ctrl)              quit-command]))

;;; ---------- resources / engine ----------

(define engine (make-engine))

(define-values (store1 a1)
  (resource-open resource-store-empty
                 #:name "editor"
                 #:text "hello, layout demo.\n\nC-w arrows split, C-b toggle filetree, C-x arrows focus, C-q quit.\n"
                 ;; per-document 键表：编辑操作
                 #:tables (list edit-command-table)))

(define state0
  (make-app-state #:resources store1
                  #:focus-resource 1
                  ;; 全局键（overlays 对所有面板生效）
                  #:overlays (command-table-stack-from-tables
                              (list global-command-table))
                  ;; 新开文档默认带编辑表（filetree 打开文件时用）
                  #:editor-tables (list edit-command-table)
                  #:area (rect 0 0 80 24)
                  #:next-panel-id 100))

(define state1 (run-actions state0 engine a1))

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
  ;; void：racket 会打印 module+ main 的返回值，别把整棵 state 吐到终端
  (void (run-app demo-state demo-engine)))
