#lang racket

;;; edit-tui-rebuild/filetree/commands.rkt —— 文件树命令 + 安装
;;;
;;; 导航（←→↑↓ / Home / End / PageUp / PageDown / Shift 扩选）由 config/keymap
;;; 复用 edit 的导航表 —— 文件树就是普通 buffer，光标归 core view，
;;; 这里的命令不碰光标。
;;;
;;; Enter:
;;;   root / dir -> 展开 / 折叠
;;;   file       -> 已打开：聚焦已有 panel；detached：进入 placement
;;;                 未打开：open-file-action（runtime 读盘 + resource-open）
;;;
;;; 打开后的目标 panel 由 placement 交互选（↑←→↓ 换 editor / Enter 放入 / Esc 取消）。
;;; 新文档的 per-doc 键表来自 keymap 的 editor-tables（通常是编辑操作表）。

(require (only-in racket/list first)
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/action.rkt"
         "../app/placement.rkt"
         "../app/keymap.rkt"
         "slice.rkt"
         "model.rkt"
         "lines.rkt")

(provide filetree-install-state
         filetree-enter-command
         filetree-refresh-command)

;;; ════════════════ 查询 ════════════════

(define (filetree-current-line state)
  (define f (filetree-of state))
  (filetree-line-at (filetree-rows f) (filetree-cursor f)))

;;; ════════════════ 打开文件 ════════════════

;; 已打开：挂在 panel 上就聚焦；detached 就进 placement。
(define (filetree-open-existing state r)
  (define store (app-state-resources state))
  (define vid (first (resource-view-ids store (resource-id r))))
  (define pid (and vid (layout-panel-for-view (app-state-layout state) vid)))
  (cond
    [(not vid)
     (values (app-state-with-message state "filetree: resource has no view") '())]
    [pid
     (values (app-state-with-message
              (app-state-set-focus-panel state pid) "file opened")
             '())]
    [else (values (start-placement state vid) '())]))

;; 未打开：交给 action（runtime 负责读盘 / resource-open / placement）。
(define (filetree-open-file state path)
  (define r (resource-find-by-path (app-state-resources state) path))
  (cond
    [r (filetree-open-existing state r)]
    [else
     (values state
             (list (open-file-action
                    (resource-normalize-path path)
                    (keymap-editor-tables (app-state-keymap state)))))]))

;;; ════════════════ 命令 ════════════════

(define (filetree-enter-command state)
  (define line (filetree-current-line state))
  (cond
    [(not line) (values (app-state-with-message state "filetree: no line") '())]
    [(memq (filetree-line-kind line) '(root dir))
     (define f (filetree-of state))
     (values (filetree-put state
                           (filetree-toggle-expand f (filetree-line-path line)))
             '())]
    [else (filetree-open-file state (filetree-line-path line))]))

;; 行投影按 (root, expanded, opened) 缓存；外部文件变化不会自动反映。
;; C-r 丢掉缓存，下一次 sync 重新扫一次目录。
(define (filetree-refresh-command state)
  (values (filetree-put state (filetree-invalidate (filetree-of state))) '()))

;;; ════════════════ 安装 ════════════════
;;;
;;; 键位表不在这里：调用方从 config/keymap 取 filetree stack，通过
;;; #:panel-stack 传进来。插件不依赖 config。

(define (filetree-install-state state view root
                                #:panel-id [panel-id 'filetree]
                                #:panel-stack panel-stack)
  (define root* (resource-normalize-path root))
  (define f (filetree-set-view
             (filetree-toggle-expand (empty-filetree) root*)
             view))
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]
               [root root*]
               [panel-stacks (hash-set (app-state-panel-stacks state)
                                       panel-id
                                       panel-stack)]))
