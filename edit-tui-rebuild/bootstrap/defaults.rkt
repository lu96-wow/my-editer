#lang racket

;;; bootstrap/defaults.rkt —— 默认 Environment（命令 + 键表 + mode）
;;;
;;; 这是可替换的“默认配置”，不是框架核心：
;;;   · 命令实现来自 bootstrap/commands.rkt；
;;;   · keymap 只存 command-id；
;;;   · 用户 / 插件用 environment-merge 覆盖同名项即可。
;;;
;;; 默认键位（最小可用）：
;;;   ←→↑↓ Home End      光标
;;;   Enter / Backspace / Delete
;;;   C-z / C-y            undo / redo
;;;   C-b                 向右切分（same document 多 view）
;;;   C-v                 向下切分
;;;   C-w                 关闭当前 view
;;;   M-←/→/↑/↓           焦点在 region 间移动
;;;   C-q                 退出

(provide default-env
         text-keys pointer-keys global-keys)

(require "../../edit-tui/command/key.rkt"
         "../../edit-tui/command/mouse.rkt"
         "../base/keymap.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/chrome.rkt"
         "../env/mode.rkt"
         "../env/rule.rkt"
         "../env/environment.rkt"
         "../env/defaults.rkt"
         "../projection/status.rkt"
         "resource-commands.rkt"
         "filetree-commands.rkt"
         "commands.rkt")

(define text-keys
  (keys
   [(key 'left)      'nav-left]
   [(key 'right)     'nav-right]
   [(key 'up)        'nav-up]
   [(key 'down)      'nav-down]
   [(key 'home)      'nav-home]
   [(key 'end)       'nav-end]
   [(key 'enter)     'insert-enter]
   [(key 'backspace) 'backspace]
   [(key 'delete)    'delete]
   [(key 'z 'ctrl)   'undo]
   [(key 'y 'ctrl)   'redo]))

(define pointer-keys
  (keys
   [(mouse 'press 'left) 'pointer-press]
   [(mouse 'move #f)      'pointer-drag]))

;; 所有 chrome / 只读面板的移动表
(define nav-keys
  (keys
   [(key 'left)  'nav-left]
   [(key 'right) 'nav-right]
   [(key 'up)    'nav-up]
   [(key 'down)  'nav-down]
   [(key 'home)  'nav-home]
   [(key 'end)   'nav-end]))

;; 输入栏是普通 document：Enter 提交 / Esc 取消，其余是编辑键。
(define input-keys
  (keys
   [(key 'enter)     'input-submit]
   [(key 'escape)    'input-cancel]
   [(key 'backspace) 'backspace]
   [(key 'delete)    'delete]
   [(key 'left)      'nav-left]
   [(key 'right)     'nav-right]
   [(key 'home)      'nav-home]
   [(key 'end)       'nav-end]))

(define global-keys
  (keys
   [(key 'x 'ctrl) (key 'f 'ctrl)  'open-file]
   [(key 'x 'ctrl) (key 's 'ctrl)  'save-current]
   [(key 'x 'ctrl) (key 'k 'ctrl)  'request-close-file]
   [(key 'x 'ctrl) (key 'd 'ctrl)  'detach-view]
   [(key 'x 'ctrl) (key 'a 'ctrl)  'attach-detached]
   [(key 'x 'ctrl) (key 'o 'ctrl)  'cycle-view]
   [(key 'x 'ctrl) (key 'p 'ctrl)  'resource-place-commit]
   [(key 'x 'ctrl) (key 'g 'ctrl)  'resource-cancel]
   [(key 'q 'ctrl)                 'request-quit]
   [(key 'n 'ctrl)                 'new-document]
   [(key 'b 'ctrl)                 'split-right]
   [(key 'v 'ctrl)                 'split-down]
   [(key 'w 'ctrl)                 'close-view]
   [(key 'w 'alt)                  'close-region]
   [(key 'left 'alt)               'focus-left]
   [(key 'right 'alt)              'focus-right]
   [(key 'up 'alt)                 'focus-up]
   [(key 'down 'alt)               'focus-down]))

(define default-env
  (environment-merge
   default-environment
   (make-environment
    #:modes (hash 'text   (make-mode #:keymaps (list text-keys pointer-keys) #:fallback 'insert)
                  'status (make-mode #:keymaps (list nav-keys pointer-keys) #:fallback 'ignore)
                  'state  (make-mode #:keymaps (list nav-keys pointer-keys) #:fallback 'ignore)
                  'input  (make-mode #:keymaps (list input-keys pointer-keys) #:fallback 'insert)
                  'resources (make-mode #:keymaps (list resource-keys pointer-keys) #:fallback 'ignore)
                  'filetree (make-mode #:keymaps (list filetree-keys pointer-keys) #:fallback 'ignore))
    #:commands (default-command-table)
    #:scopes (hash 'placing placement-scope)
    #:rules (list (make-rule 'placing placement-keys))
    #:keymaps (hash 'global global-keys)
    #:input-commands (append (default-input-commands)
                             filetree-input-commands)
    #:status full-status-parts
    #:handlers (hash 'job-done
                     (λ (s payload)
                       (transition-pure
                        (state-chrome* s
                                       (λ (c)
                                         (chrome-set-message
                                          c (format "job done: ~a" payload))))))))))
