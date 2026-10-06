#lang racket

(require "../../core/editor.rkt"
         "../platform/state.rkt"
         "../platform/paths.rkt"
         "../platform/hooks.rkt"
         "../config/defaults.rkt"
         "../config/plugins.rkt"
         "highlight/manager.rkt"
         "highlight/runner.rkt"
         "highlight/runner-place.rkt"
         "highlight/registry.rkt")

;;; lab-rebuild/builtin/highlight.rkt —— 属性插件（font-lock 类）包
;;;
;;; 把「按 document 版本增量算属性（高亮 / 只读）+ 异步 worker」这套接进平台：
;;;   · after-edit       → 记录 text 增量（manager-note-change!）
;;;   · document-closed  → 清 per-doc 状态（manager-forget!）
;;;   · before-render    → 同步（派活）+ poll（写回属性）
;;;   · app-job-add-source! → 把 worker 结果源交给后端唤醒
;;;
;;; 插件实现（brackets / words / syntax）在 highlight/ 下，按名字从 registry 解析；
;;; 启用集来自 config/plugins.rkt。后台 place 在 app-init（with-tui 内）才创建。

(provide highlight-init!)

;; 真实文件（有路径）的 (did path) 列表；内部面板文档不参与。
(define (doc-infos a)
  (for/list ([did (in-list (editor-document-id-list (app-ed a)))]
             #:when (path-table-path (app-paths a) did))
    (list did (path-table-path (app-paths a) did))))

;; core 的 change → 插件层的 diff（插入文本从新文档 after 区间读）。
(define (note-change! m a vid changes)
  (when (pair? changes)
    (define ed (app-ed a))
    (define did (editor-view-document-id ed vid))
    (when (path-table-path (app-paths a) did)
      (define edits
        (for/list ([ch (in-list changes)])
          (define b (change-before ch))
          (define s (range-start b))
          (define e (range-end b))
          (list (point-line s) (point-column s)
                (point-line e) (point-column e)
                (editor-view-change-text ed vid ch))))
      (manager-note-change! m did edits))))

(define (highlight-init! a #:background? [background? (current-background?)])
  (when (pair? attr-plugin-names)
    (define runner
      (if background?
          (make-place-runner plugin-worker-count)
          (make-sync-runner enabled-attr-plugins)))
    (define m (make-manager enabled-attr-plugins runner
                            #:history-bound plugin-history-bound))
    ;; 每次事件（job-tick）与每帧（before-render）都 flush 一次：
    ;; manager 的 pending 只存“上一批”增量，必须在下一个编辑命令前 sync 掉，
    ;; 否则两次编辑之间没渲染时会丢中间增量。
    (define (tick app)
      (manager-sync! m (app-ed app) (doc-infos app))
      (manager-poll! m (app-ed app)))
    (hook-add! a 'after-edit (lambda (app vid changes) (note-change! m app vid changes)))
    (hook-add! a 'document-closed (lambda (app did) (manager-forget! m did)))
    (hook-add! a 'job-tick (lambda (app) (tick app)))
    (hook-add! a 'before-render (lambda (app) (tick app)))
    ;; 后台 runner 的结果源（sync runner 为 #f，不影响）。
    (app-job-add-source! a (lambda () (manager-source m))))
  a)
