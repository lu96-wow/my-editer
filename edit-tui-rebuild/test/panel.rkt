#lang racket

;;; edit-tui-rebuild/test/panel.rkt —— 面板装配原语 + “可拆”基线
;;;
;;; 覆盖：
;;;   1. panel-install! 建出 doc/view/region，role/mode/name 正确；
;;;   2. panel-uninstall! 把 state / engine / layout 完整还原（可重复调用）；
;;;   3. 面板没安装时，sync-*-panel! 是 no-op（不崩、不建东西）；
;;;   4. environment-panel-syncs 的注册与 merge 顺序；
;;;   5. panel-sync-buffer! 写文本 / face / 夹光标。
;;;
;;; 第 2、3 条就是“文件树 / 资源面板可拆”的基线：
;;; 拆掉插件后 run-frame 只遍历一张空表，投影与状态都不引用插件数据。

(require rackunit
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/resources.rkt"
         "../model/filetree.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../env/environment.rkt"
         "../bootstrap/panel.rkt"
         "../bootstrap/resource-plugin.rkt"
         "../bootstrap/filetree-plugin.rkt"
         "../bootstrap/defaults.rkt"
         "../../core/editor/ops.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt")

(define erid (region-id 1))
(define prid (region-id 2))
(define srid (region-id 3))

;;; ════════════════ 1. 安装 ════════════════

(define engine (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 1 1)))
(define s0* (panel-region-install! s0 erid #:role 'editor))
(define-values (s1 v1)
  (panel-install! engine s0* prid #:name "*probe*" #:mode 'probe #:role 'tool))

(define ws1 (state-workspace s1))
(check-equal? (hash-count (workspace-docs ws1)) 1)
(check-equal? (hash-count (workspace-views ws1)) 1)
(check-equal? (hash-count (workspace-regions ws1)) 2)
(check-equal? (doc-meta-name (workspace-doc ws1 (view-meta-doc (workspace-view ws1 v1))))
              "*probe*")
(check-equal? (doc-meta-mode (workspace-doc ws1 (view-meta-doc (workspace-view ws1 v1))))
              'probe)
(check-equal? (region-role (workspace-region ws1 prid)) 'tool)
(check-equal? (region-active (workspace-region ws1 prid)) v1)
(check-true (engine-view-exists? engine v1))
;; id 分配器已前进，不会和已有 id 撞。
(check-equal? (id-n v1) 1)
(check-equal? (id-counter-view (state-ids s1)) 2)

;; 布局里只放了两个叶子。
(define lay (make-split 'lr (list (make-leaf erid (flex 1))
                                  (make-leaf prid (fixed 20)))
                        (flex 1)))
(define s2 (state-set-workspace s1
                                (struct-copy workspace (state-workspace s1) [layout lay])))
(check-equal? (tree-visible-regions (workspace-layout (state-workspace s2)))
              (list erid prid))

;;; ════════════════ 2. 卸载（完整还原） ════════════════

(define s3 (panel-uninstall! engine s2 prid))
(define ws3 (state-workspace s3))
(check-equal? (hash-count (workspace-docs ws3)) 0)
(check-equal? (hash-count (workspace-views ws3)) 0)
(check-equal? (hash-count (workspace-regions ws3)) 1)
(check-equal? (tree-visible-regions (workspace-layout ws3)) (list erid))
(check-false (engine-view-exists? engine v1))
(check-equal? (region-role (workspace-region ws3 erid)) 'editor)
;; 可重复调用
(check-equal? (panel-uninstall! engine s3 prid) s3)
;; 不存在的 region 也是 no-op
(check-equal? (panel-uninstall! engine s3 (region-id 99)) s3)

;;; ════════════════ 3. 没装面板时 sync 是 no-op ════════════════

(define empty-engine (make-engine))
(define empty-state (make-state))
(check-equal? (resource-view empty-state) #f)
(check-equal? (filetree-panel-view empty-state) #f)
(check-eqv? (sync-resource-panel! empty-state empty-engine) (void))
(check-eqv? (sync-filetree-panel! empty-state empty-engine) (void))
;; 没有建出任何对象
(check-equal? (hash-count (workspace-docs (state-workspace empty-state))) 0)

;; 装了之后 sync 会写 buffer；拆掉之后回到“不写”。
(define fs0 (install-filetree-panel! engine s0 srid (current-directory)))
(define fvid (filetree-panel-view fs0))
(check-true (view-id? fvid))
(sync-filetree-panel! fs0 engine)
(check-true (positive? (string-length
                        (engine-view-view-text (make-engine-view engine) fvid))))
(define fs1 (panel-uninstall! engine
                             (plugin-state* fs0 'filetree (λ (f) (filetree-set-view f #f)) (empty-filetree))
                             srid))
(check-equal? (filetree-panel-view fs1) #f)
(check-eqv? (sync-filetree-panel! fs1 engine) (void))

;;; ════════════════ 4. environment.panel-syncs ════════════════

(define f1 (λ (s e) 'a))
(define f2 (λ (s e) 'b))
(check-equal? (environment-panel-syncs (environment-empty)) '())
(check-equal? (environment-panel-syncs
               (environment-add-panel-sync (environment-empty) f1))
              (list f1))
;; 合并：a 的在前，b 的在后（装配顺序 = 执行顺序）
(check-equal? (environment-panel-syncs
               (environment-merge (environment-add-panel-sync (environment-empty) f1)
                                  (environment-add-panel-sync (environment-empty) f2)))
              (list f1 f2))
;; 默认 env 已注册两个面板同步器
(check-equal? (length (environment-panel-syncs default-env)) 2)

;;; ════════════════ 5. panel-sync-buffer! ════════════════

(define engine2 (make-engine))
(define-values (b0 bvid)
  (panel-install! engine2 (make-state #:ids (make-id-counter 1 1 1 1))
                  (region-id 1) #:name "*b*" #:mode 'probe #:role 'tool))
(panel-sync-buffer! engine2 b0 bvid
                    #:texts (list "alpha" "beta")
                    #:faces (list 'face-a #f))
(define bv (engine-view-object engine2 bvid))
(check-equal? (buffer-string (view-buffer bv)) "alpha\nbeta")
(check-equal? (view-point-line bv) 0)
;; 光标夹到最后一行长度内
(view-set-selections! bv (selections-one (caret (point 9 9))))
(panel-sync-buffer! engine2 b0 bvid #:texts (list "x") #:faces (list #f))
(check-equal? (buffer-string (view-buffer bv)) "x")
(check-equal? (view-point-line bv) 0)
(check-equal? (view-point-column bv) 1)
