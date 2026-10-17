#lang racket

;;; bootstrap/resource-panel.rkt —— 资源列表面板（buffer 支撑）
;;;
;;; 安装一个 *resources* document/view，挂在 role='resource 的 region。
;;; 每帧 sync：
;;;   · 从 workspace.docs / workspace.views 生成行；
;;;   · document 行绿色 = 有 attached view；黄色 = 只有 detached view / 无 view；
;;;   · view 行缩进在 doc 下，可折叠；
;;;   · view 行显示 region / active / detached / placing。
;;;
;;; 读写接口：
;;;   install-resource-panel!
;;;   sync-resource-panel!
;;;   resource-view

(provide install-resource-panel! sync-resource-panel! resource-view)
(provide (all-from-out "../projection/resources.rkt"))

(require "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/resources.rkt"
         "../effects/engine.rkt"
         "../projection/resources.rkt"
         "../../core/editor/ops.rkt"
         "../../core/editor/attributes.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/range.rkt")

(define (resource-view state)
  (resources-view (state-resources state)))

(define (install-resource-panel! engine state region-id)
  (define-values (did s1) (state-next-id state 'doc))
  (define-values (vid s2) (state-next-id s1 'view))
  (void (engine-create-doc! engine did "*resources*" ""))
  (void (engine-create-view! engine vid did))
  (define ws (state-workspace s2))
  (define ws1 (workspace-add-doc ws did (make-doc-meta "*resources*" #:mode 'resources)))
  (define ws2 (workspace-add-view ws1 vid (view-meta did (hash))))
  (define reg (region region-id (list (view-member vid)) vid 'resource))
  (define ws3 (workspace-add-region ws2 region-id reg))
  (state-resources*
   (state-set-workspace s2 ws3)
   (λ (r) (resources-set-view r vid))))

(define (apply-faces! b lines)
  (for ([line (in-list lines)] [i (in-naturals)])
    (define face (resource-line-face line))
    (buffer-face-range! b
                        (range-of (point i 0)
                                  (point i (string-length (resource-line-text line))))
                        face)))

(define (sync-resource-panel! state engine)
  (define rvid (resource-view state))
  (when rvid
    (define ev (make-engine-view engine))
    (define v (engine-view-object engine rvid))
    (when v
      (define b (view-buffer v))
      (define lines (resource-lines state))
      (define text (string-join (map resource-line-text lines) "\n"))
      (define old-line (view-point-line v))
      (define old-col (view-point-column v))
      (unless (string=? text (buffer-string b))
        (buffer-set-document! b text))
      (apply-faces! b lines)
      ;; 光标夹到新文本内；资源面板 focused 时确保可见。
      (define n (length lines))
      (define line (if (zero? n) 0 (min old-line (sub1 n))))
      (define lstr (if (zero? n) "" (resource-line-text (list-ref lines line))))
      (define col (min old-col (string-length lstr)))
      (view-set-selections! v
                            (selections-one (caret (point line col)))
                            #:ensure? (equal? (state-focus state) rvid))))
  (void))
