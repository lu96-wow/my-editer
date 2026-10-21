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
;;;   Backspace     删前一个字符      Delete  删后一个字符
;;;   C-d           close-panel：删除当前 editor panel；最后一个只清 view
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
;;;   滚轮          滚动指针下的 panel
;;;   点 buffer 内容 把主光标放到点击处（filetree 也只是普通 buffer）
;;;
;;; 文件树 / placement：
;;;   filetree 就是普通 buffer：←→↑↓ / Home End 自由移动光标（列不钉死在行首），
;;;   PageUp/Down 滚一屏；Enter 展开目录 / 打开文件（已打开则聚焦 / 进入 placement）
;;;   placement 中：↑←→↓ 在 editor 间改焦点，Enter 放入，Esc 取消，
;;;     鼠标点目标 editor 也可（放完临时表自动解除）

(require "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt"
         "../config/layout/default.rkt"
         "../config/theme/default.rkt"
         "../main.rkt")

(provide demo-state demo-engine)

;;; ---------- resources / engine ----------

(define engine (make-engine))

(define state0
  (make-app-state #:resources resource-store-empty
                  ;; 启动不预打开任何 buffer：没有 layout 时焦点 resource 自然为空
                  ;; 具体布局规则：宿主选择，layout 骨架不认识它
                  #:layout-config default-config
                  ;; 键位集合：全局 / 编辑 / 输入 / placement
                  #:keymap default-keymap
                  #:area (rect 0 0 80 24)
                  #:next-panel-id 100))

(define state1 state0)

;;; filetree 自己的 core view：doc=10, view=10
(void (engine-create-buffer! engine 10 "*filetree*" ""))
(void (engine-create-view! engine 10 10))
(void (engine-create-buffer! engine 20 "*status*" ""))
(void (engine-create-view! engine 20 20))
(void (engine-create-buffer! engine 21 "*input*" ""))
(void (engine-create-view! engine 21 21))

(define state2
  (filetree-install-state state1 10 (current-directory)
                          #:panel-stack filetree-panel-stack))
(define state3 (status-install-state state2 20))
(define state4 (input-install-state state3 'status 20 21))

;;; view ids: filetree=10, status=20, input=21；editor 启动时为空

;;; ---------- layout ----------

(define editor-panel
  (make-panel 'editor 'editor
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
