#lang racket

(require racket/file
         racket/path
         "../../core/editor.rkt"
         "../base/layout/main.rkt"
         "../ui/tree.rkt"
         "../ui/buffers.rkt"
         "../ui/slot.rkt"
         "../ui/mode.rkt"
         "state.rkt"
         "panes.rkt"
         "edit-panes.rkt"
         "paths.rkt")

;;; lab/app/actions.rkt —— 业务动作：唯一改 app / editor 的地方
;;;
;;; 命令转发（commands.rkt）只做「命令 → 调这里的函数」；这里负责所有状态变更，
;;; 并把生命周期不变量收在少数几个函数里（打开 / 关闭 / 聚焦 / 提示）。

(provide app-bufs-exclude
         app-tree-refresh! app-tree-activate! app-tree-new-file! app-tree-new-dir! app-tree-delete!
         app-open-path! app-close-path! app-close-view! app-close-document!
         app-show-view! app-show-document! app-split! app-pane-close!
         app-bufs-refresh! app-bufs-activate! app-bufs-close! app-bufs-new-view! app-save!
         app-toggle-focus! app-toggle-left! app-move-focus!
         app-prefix-begin! app-prefix-end!
         app-begin! app-commit! app-answer! app-cancel! app-resize!
         app-quit!)

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

;; 路径被删 → 同步关掉它（及子路径）对应的文档 / 视图，并从编辑区移除。
(define (app-close-path! a path)
  (define closed (path-table-dids-under (app-paths a) path))
  (when (pair? closed)
    (define ed (app-ed a))
    (define vids (append* (for/list ([did (in-list closed)])
                            (editor-document-view-list ed did))))
    (for ([did (in-list closed)])
      (set-app-ed! a (editor-close-document (app-ed a) did))
      (path-table-remove! (app-paths a) did))
    (app-edit-remove! a vids)
    (app-edit-recover! a)))

;; 关闭动作后：编辑区空了但还有 view → 把第一个可用的放进 active 窗格。
(define (app-edit-recover! a)
  (unless (app-edit-active a)
    (define v (app-pick-edit-vid a))
    (when v (app-edit-open! a v)))
  (app-bufs-refresh! a))

;; 关闭整个文档：连带它**所有** view。
(define (app-close-document! a did)
  (define ed (app-ed a))
  (define vids (editor-document-view-list ed did))
  (set-app-ed! a (editor-close-document ed did))
  (app-edit-remove! a vids)
  (path-table-remove! (app-paths a) did)
  (buffers-collapse! (app-bufs a) did)
  (app-edit-recover! a))

;; 关闭单个 view：**文档保留**（即使这是它最后一个 view，也只是变成没有 view 的文档）。
(define (app-close-view! a vid)
  (set-app-ed! a (editor-close-view (app-ed a) vid))
  (app-edit-remove! a (list vid))
  (app-edit-recover! a))

;; 把某个 view 显示到 active 编辑窗格（view 是持久对象，旧 view 不关）。
;; focus? = #f 时只换编辑格内容，不动焦点（文件树打开文件的默认行为）。
;; 把某个 view 显示到 active 编辑窗格。
;; ⚠ 同一 view 不能同时占两个编辑窗格：如果它已经在**别的** leaf 里显示，就为这个窗格
;;    新建一个同文档的 view（保持两个窗格独立，且避免树里出现重复 vid）。
(define (app-show-view! a vid [focus? #t])
  (define did (editor-view-document-id (app-ed a) vid))
  (define active (app-edit-active a))
  (define vid*
    (if (and (edit-panes-contains? (app-edit a) vid) (not (eqv? vid active)))
        (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                               #:line-numbers? #t)])
          (set-app-ed! a ed2) v2)
        vid))
  (app-edit-open! a vid*)
  (when focus? (set-app-focus! a vid*))
  (app-bufs-refresh! a))

;; 把某个 did 显示到 active 编辑窗格：优先用它**没被别的窗格占用**的 view，没有再建。
(define (app-show-document! a did [focus? #t])
  (define used (edit-panes-vids (app-edit a)))
  (define free (for/first ([v (in-list (editor-document-view-list (app-ed a) did))]
                           #:unless (memv v used)) v))
  (define vid (or free
                  (let-values ([(ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                                         #:line-numbers? #t)])
                    (set-app-ed! a ed2) v2)))
  (app-show-view! a vid focus?))

;;; ================= 编辑区分屏 =================

;; 拆分 active 编辑窗格：新窗格显示同一文档的**新 view**（独立光标 / 滚动）。
;; dir : 'lr 左右 | 'tb 上下。没有编辑窗格 → 不做。
(define (app-split! a dir)
  (define vid (app-edit-active a))
  (when vid
    (define did (editor-view-document-id (app-ed a) vid))
    (define-values (ed2 v2) (editor-add-view (app-ed a) did (app-main-w a) (app-main-h a)
                                             #:line-numbers? #t))
    (set-app-ed! a ed2)
    (app-edit-split! a dir v2)
    (set-app-focus! a v2)
    (app-bufs-refresh! a)))

;; 关闭 active 编辑窗格：只撤窗格，**不关 view**（view 仍在文档列表里）。
;; 关闭当前**有焦点**的编辑窗格（不是按顺序 / 不是 last-split）；
;; 关完剩下那个会由 compute-layout 自动补满主区；焦点跟到新的 active，没有就回左栏。
;; 焦点不在编辑区时，回落到 active 编辑窗格。
(define (app-pane-close! a)
  (define f (app-focus a))
  (define vid (if (and f (edit-panes-contains? (app-edit a) f)) f (app-edit-active a)))
  (when vid
    (define was-focus? (eqv? f vid))
    (app-edit-remove! a (list vid))
    (when was-focus?
      (set-app-focus! a (or (app-edit-active a) (app-left-vid a))))
    (app-bufs-refresh! a)))

;;; ================= 文档列表 =================

(define (app-bufs-refresh! a)
  (buffers-refresh! (app-ed a) (panes-bufs (app-panes a)) (app-bufs a)
                    (app-edit-active a)
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

;; 按几何邻居移焦点（前缀键方向用）。
(define (app-move-focus! a dir)
  (define vid (pane-dir (app-focus-panes a) (app-focus a) dir))
  (when vid (set-app-focus! a vid)))

(define (app-toggle-focus! a)
  (define p (app-panes a))
  (define ev (app-edit-active a))
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

;; 前缀键：进入一个只认 tables 的瞬时状态；下一次按键后由 app 退出（见 app-dispatch!）。
(define (app-prefix-begin! a label tables)
  (app-mode-set! a (prefix-begin label tables)))

(define (app-prefix-end! a)
  (when (prefix? (app-mode a)) (app-mode-set! a #f)))

(define (app-begin! a label editable? on-commit [on-cancel #f])
  (define p (input-begin label editable? (app-focus a) on-commit on-cancel))
  (app-mode-set! a p)
  (define vid (app-modal-vid a))
  (editor-view-assign! (app-ed a) vid (prompt-document p ""))
  (editor-view-set-point! (app-ed a) vid (point 0 (string-length label)))
  (set-app-focus! a vid))

(define (app-commit! a)
  (define p (app-mode a))
  (when (and (prompt? p) (prompt-editable? p))
    (define s (editor-view-string (app-ed a) (app-modal-vid a)))
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-commit p s)))

(define (app-answer! a yes?)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-answer p yes?)))

(define (app-cancel! a)
  (define p (app-mode a))
  (when (prompt? p)
    (app-mode-set! a #f)
    (set-app-focus! a (prompt-prev-focus p))
    (input-cancel p)))

;;; ================= 保存 / 退出 / 尺寸 =================

(define (app-quit! a) (set-app-quit?! a #t))

(define (app-save! a)
  (define did (focused-did a))
  (define p (and did (path-table-path (app-paths a) did)))
  (when p
    (call-with-output-file p #:exists 'replace
      (lambda (out) (display (editor-document-string (app-ed a) did) out)))))

(define (app-resize! a w h)
  (app-size-set! a (max 20 w) (max 5 h))
  (set-app-prev! a #f))
