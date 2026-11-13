#lang racket

;;; edit-tui/app/bootstrap.rkt —— engine / 初始文档 / 初始布局 / 插件装配
;;;
;;; 这里只回答“应用启动时创建什么”，不处理事件循环和渲染。
;;; 具体面板 kind 的布局装配在 app/layout.rkt；键表在 host/keymap.rkt。

(require racket/string
         "../editor/host-api.rkt"
         "../features/input/api.rkt"
         "../plugins/pair/plugin.rkt"
         "../plugins/indent/plugin.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../plugins/layout/plugin.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/resources/plugin.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/docs/plugin.rkt"
         "../host/keymap.rkt"
         "../host/workspace.rkt"
         "layout.rkt")

(provide editor-vid
         status-vid
         filetree-vid
         resources-vid
         input-vid
         completion-vid
         docs-vid
         make-editor-app)

;;; ════════════════ 初始文档 ════════════════

(define editor-vid 1)
(define status-vid 2)
(define filetree-vid 3)
(define resources-vid 4)
(define input-vid 5)
(define completion-vid 6)
(define docs-vid 7)

(define (make-editor-app
         #:workspace-root [workspace-root (resource-normalize-path (current-directory))]
         #:initial-text [initial-text ""]
         #:initial-name [initial-name ""]
         #:initial-path [initial-path #f]
         #:initial-resource? [initial-resource? (not (string=? initial-name ""))])
  (define engine (make-engine))
  (void (engine-create-buffer! engine editor-vid initial-name initial-text))
  (void (engine-create-view! engine editor-vid editor-vid))
  (void (engine-create-buffer! engine status-vid "*status*" "" #:kind 'ui))
  (void (engine-create-view! engine status-vid status-vid))
  (void (engine-create-buffer! engine filetree-vid "*filetree*" "" #:kind 'ui))
  (void (engine-create-view! engine filetree-vid filetree-vid))
  (void (engine-create-buffer! engine resources-vid "*resources*" "" #:kind 'ui))
  (void (engine-create-view! engine resources-vid resources-vid))
  (void (engine-create-buffer! engine input-vid "*input*" "" #:kind 'ui))
  (void (engine-create-view! engine input-vid input-vid))
  (void (engine-create-buffer! engine completion-vid "*completion*" "" #:kind 'ui))
  (void (engine-create-view! engine completion-vid completion-vid))
  (void (engine-create-buffer! engine docs-vid "*docs*" "" #:kind 'ui))
  (void (engine-create-view! engine docs-vid docs-vid))
  ;; 从文档开头启动；避免 viewport 还没 sync 时把 top-line 锚在末尾。
  (engine-set-view-cursor! engine editor-vid 0 #:column 0)

  (define plugins (list pair-plugin
                        indent-plugin
                        (make-filetree-plugin
                         #:view filetree-vid
                         #:root workspace-root)
                        (make-resources-plugin #:view resources-vid)
                        racket-color-plugin
                        layout-plugin
                        (make-completion-plugin #:view completion-vid)
                        (make-docs-plugin #:view docs-vid #:panel-id 'docs)))
  (define registry (make-hook-registry (plugins->hooks plugins)))
  (define ed (make-editor #:engine engine
                          #:registry registry
                          #:plugins plugins))
  (define view-scopes (plugins->view-scopes plugins))

  (define layout (make-editor-layout #:editor-view editor-vid
                                     #:status-views (list status-vid input-vid)
                                     #:sidebar-views (list filetree-vid resources-vid)
                                     #:docs-view docs-vid))
  ;; 没有 initial-name 时只建一个空 editor buffer，不登记 resource。
  ;; 打开文件后由 host/open 创建真正的 resource。
  (define initial-mode (doc-mode-for initial-path initial-text))
  (define resources*
    (if initial-resource?
        (resources-add
         empty-resources
         (make-resource editor-vid editor-vid initial-path initial-name
                        (list editor-vid) initial-mode
                        (engine-doc-version engine editor-vid)
                        #:command-stack (mode-command-stack initial-mode)))
        empty-resources))
  (define state
    (make-app-state #:plugin-states (plugins->states plugins)
                    #:workspace-root workspace-root
                    #:area (rect 0 0 80 24)
                    #:layout layout
                    #:layout-config default-layout-config
                    #:view-scopes view-scopes
                    #:next-view-id 10
                    #:next-panel-id 100
                    #:resources resources*
                    #:input (make-input-state #:panel-id 'status
                                              #:status-view status-vid
                                              #:input-view input-vid)))
  ;; 初始 workspace：打开文档的分析快照。之后由 frame 每帧同步。
  (workspace-sync! ed state)
  (values ed state))
