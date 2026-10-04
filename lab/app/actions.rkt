#lang racket

(require racket/file
         racket/path
         "../../core/editor.rkt"
         "../ui/tree.rkt"
         "../ui/buffers.rkt"
         "../ui/slot.rkt"
         "../ui/mode.rkt"
         "state.rkt"
         "panes.rkt"
         "paths.rkt")

;;; lab/app/actions.rkt —— 业务动作：唯一改 app / editor 的地方
;;;
;;; 命令表（commands.rkt）只做「事件 → 调这里的函数」；这里负责所有状态变更，
;;; 并把生命周期不变量收在少数几个函数里（打开 / 关闭 / 聚焦 / 提示）。

(provide app-bufs-exclude
         app-tree-refresh! app-tree-activate! app-tree-new-file! app-tree-new-dir! app-tree-delete!
         app-open-path! app-close-path! app-close-view! app-close-document!
         app-show-view! app-show-document!
         app-bufs-refresh! app-bufs-activate! app-bufs-close! app-bufs-new-view! app-save!
         app-toggle-focus! app-toggle-left!
         app-begin! app-commit! app-answer! app-cancel! app-resize!)

;;; ================= 小工具 =================

(define (basename p)
  (path->string (file-name-from-path (simplify-path p))))

;; 不该进「已打开文档」列表的内部 did。
(define (app-bufs-exclude a)
  (for/list ([vid (in-list (panes-internal (app-panes a)))])
    (editor-view-document-id (app-ed a) vid)))

;;; ================= 文件树 =================

(define (app-tree-refresh! a)
  (tree-refresh! (app-ed a) (panes-tree (app-panes a)) (app-tree a)
                 #:open? (lambda (p) (path-table-open? (app-paths a) p))))

(define (app-tree-entry-at-focus a)
  (tree-line->entry (app-tree a)
                    (editor-view-point-line (app-ed a) (panes-tree (app-panes a)))))

(define (app-tree-activate! a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (void)]
        [(entry-dir? e) (file-tree-toggle! (app-tree a) (entry-path e)) (app-tree-refresh! a)]
        [else (app-open-path! a (entry-path e))]))

(define (app-target-dir a)
  (define e (app-tree-entry-at-focus a))
  (cond [(not e) (file-tree-root (app-tree a))]
        [(entry-dir? e) (entry-path e)]
        [else (let-values ([(base _name _dir?) (split-path (entry-path e))]) base)]))

(define (app-tree-new-file! a)
  (define target (app-target-dir a))
  (app-begin! a "new file: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-file! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

(define (app-tree-new-dir! a)
  (define target (app-target-dir a))
  (app-begin! a "new folder: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-dir! target name))
                  (file-tree-expand! (app-tree a) target)
                  (app-tree-refresh! a)))))

(define (app-tree-delete! a)
  (define e (app-tree-entry-at-focus a))
  (when e
    (define p (entry-path e))
    (app-begin! a (format "delete ~a? (y/n)" (entry-name e)) #f
                (lambda (yes?)
                  (when yes?
                    (tree-delete-path! p)
                    (app-close-path! a p)
                    (app-tree-refresh! a))))))

;;; ================= 打开 / 关闭 / 显示 =================

(define (app-open-path! a path)
  (define np (simplify-path (path->complete-path path)))
  (define did
    (or (path-table-did (app-paths a) np)
        (let-values ([(ed2 d2) (editor-add-document (app-ed a)
                                                    (if (file-exists? np) (file->string np) "")
                                                    (basename np))])
          (set-app-ed! a ed2)
          (path-table-add! (app-paths a) d2 np)
          d2)))
  (app-tree-refresh! a)
  (app-show-document! a did #f))

;; 已打开文档里挑一个 view 给编辑格（不新建 view）。
(define (app-pick-edit-vid a)
  (for/or ([did (in-list (editor-document-id-list (app-ed a)))]
           #:unless (memv did (app-bufs-exclude a)))
    (define vids (editor-document-view-list (app-ed a) did))
    (and (pair? vids) (car vids))))

;; 路径被删 → 同步关掉它（及子路径）对应的文档 / 视图。
;; 如果编辑格正显示被关的文档，改显下一个还开着的 view（没有就空）。
(define (app-close-path! a path)
  (define closed (path-table-dids-under (app-paths a) path))
  (when (pair? closed)
    (define ed (app-ed a))
    (define old-edit (panes-edit (app-panes a)))
    (define edit-did (and old-edit (editor-view-document-id ed old-edit)))
    (for ([did (in-list closed)])
      (set-app-ed! a (editor-close-document (app-ed a) did))
      (path-table-remove! (app-paths a) did))
    (app-edit-recover! a old-edit (and edit-did (memv edit-did closed) #t))))

;; 关闭动作后：如果编辑格原来显示的东西被关了（edit-gone?），改显下一个还开着的 view。
(define (app-edit-recover! a old-edit edit-gone?)
  (when edit-gone?
    (app-edit-vid-set! a (app-pick-edit-vid a))
    (when (eqv? (app-focus a) old-edit)
      (set-app-focus! a (app-left-vid a))))
  (app-bufs-refresh! a))

;; 关闭整个文档：连带它**所有** view。
(define (app-close-document! a did)
  (define ed (app-ed a))
  (define old-edit (panes-edit (app-panes a)))
  (define edit-gone? (and old-edit (eqv? (editor-view-document-id ed old-edit) did)))
  (set-app-ed! a (editor-close-document ed did))
  (path-table-remove! (app-paths a) did)
  (buffers-collapse! (app-bufs a) did)
  (app-edit-recover! a old-edit edit-gone?))

;; 关闭单个 view：**文档保留**（即使这是它最后一个 view，也只是变成没有 view 的文档）。
(define (app-close-view! a vid)
  (define old-edit (panes-edit (app-panes a)))
  (define edit-gone? (eqv? old-edit vid))
  (set-app-ed! a (editor-close-view (app-ed a) vid))
  (app-edit-recover! a old-edit edit-gone?))

;; 把某个 view 显示到编辑格（view 是持久对象，旧 view 不关）。
;; focus? = #f 时只换编辑格内容，不动焦点（文件树打开文件的默认行为）。
(define (app-show-view! a vid [focus? #t])
  (app-edit-vid-set! a vid)
  (when focus? (set-app-focus! a vid))
  (app-bufs-refresh! a))

;; 把某个 did 显示到编辑格（复用它的第一个视图，没有再建）。
(define (app-show-document! a did [focus? #t])
  (define vids (editor-document-view-list (app-ed a) did))
  (define vid (if (pair? vids) (car vids)
                  (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                                          #:line-numbers? #t)])
                    (set-app-ed! a ed2) v2)))
  (app-show-view! a vid focus?))

;;; ================= 文档列表 =================

(define (app-bufs-refresh! a)
  (buffers-refresh! (app-ed a) (panes-bufs (app-panes a)) (app-bufs a)
                    (panes-edit (app-panes a))
                    #:exclude (app-bufs-exclude a)
                    #:path-of (lambda (did) (path-table-path (app-paths a) did))))

(define (app-bufs-row-at-focus a)
  (define line (editor-view-point-line (app-ed a) (panes-bufs (app-panes a))))
  (buffers-line->row (app-ed a) (app-bufs a) line
                     #:exclude (app-bufs-exclude a)
                     #:path-of (lambda (did) (path-table-path (app-paths a) did))))

(define (app-bufs-activate! a)
  (define row (app-bufs-row-at-focus a))
  (case (and row (buffer-row-kind row))
    [(doc)  (buffers-toggle! (app-bufs a) (buffer-row-did row)) (app-bufs-refresh! a)]
    [(view) (app-show-view! a (buffer-row-vid row))]
    [else (void)]))

;; Backspace：view 行关 view（最后一个 view → 关文档），doc 行关文档。
(define (app-bufs-close! a)
  (define row (app-bufs-row-at-focus a))
  (case (and row (buffer-row-kind row))
    [(view) (app-close-view! a (buffer-row-vid row))]
    [(doc)  (app-close-document! a (buffer-row-did row))]
    [else (void)]))

;; Ctrl+N：给当前行的文档再开一个 view（doc / view 行都行）。
;; 不抢焦点：展开该文档让新 view 行可见，光标留在面板上。
(define (app-bufs-new-view! a)
  (define row (app-bufs-row-at-focus a))
  (define did (and row (buffer-row-did row)))
  (when did
    (define-values (ed2 _v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                              #:line-numbers? #t))
    (set-app-ed! a ed2)
    (buffers-expand! (app-bufs a) did)
    (app-bufs-refresh! a)))

;;; ================= 焦点 =================

(define (app-toggle-focus! a)
  (define p (app-panes a))
  (define ev (panes-edit p))
  (when ev
    (set-app-focus! a (if (memv (app-focus a) (list (panes-tree p) (panes-bufs p)))
                          ev
                          (app-left-vid a)))))

;; 左侧面板：文件树 ↔ 文档列表。
(define (app-toggle-left! a)
  (app-left-set! a (if (eq? (app-left a) 'tree) 'bufs 'tree))
  (app-bufs-refresh! a)
  (set-app-focus! a (app-left-vid a)))

;;; ================= 输入转移（续延回传） =================
;;
;; 命令表的选择交给 dispatch（mode-tables），这里只管「挂文档 / 聚焦 / 退出模态」。

(define (app-begin! a label editable? on-commit [on-cancel #f])
  (define p (input-begin label editable? (app-focus a) on-commit on-cancel))
  (app-mode-set! a p)
  (define vid (app-modal-vid a))
  (editor-view-assign! (app-ed a) vid (prompt-document p ""))
  (editor-view-set-point! (app-ed a) vid (point 0 (string-length label)))
  (set-app-focus! a vid))

(define (app-commit! a)
  (define p (app-mode a))
  (when (and p (prompt-editable? p))
    (define s (editor-view-string (app-ed a) (app-modal-vid a)))
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-commit p s)))

(define (app-answer! a yes?)
  (define p (app-mode a))
  (when p
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-answer p yes?)))

(define (app-cancel! a)
  (define p (app-mode a))
  (when p
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-cancel p)))

;;; ================= 保存 / 尺寸 =================

(define (app-save! a)
  (define did (focused-did a))
  (define p (and did (path-table-path (app-paths a) did)))
  (when p
    (call-with-output-file p #:exists 'replace
      (lambda (out) (display (editor-document-string (app-ed a) did) out)))))

(define (app-resize! a w h)
  (app-size-set! a (max 20 w) (max 5 h))
  (set-app-prev! a #f))
