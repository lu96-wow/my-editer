#lang racket

;;; ============================================================================
;;; api.rkt —— core 对外的唯一原子门面
;;; ============================================================================
;;;
;;; 使用方一律 (require "core/api.rkt")。core/text/*、core/view/* 是内部实现，不直接 require。
;;; 工具层/组合层（core/tool/history.rkt、core/compose/editor.rkt）在门面之上，按需直接 require。
;;;
;;; 门面**零逻辑**：只做显式白名单转发。新增内部函数不会自动泄漏。
;;; 导出分三类：
;;;   消费者层：point / edit-desc / buffer / window / screen / events / document / patch / width
;;;   机制层：buffer-apply-edit(-trusted/-batch) / edit-desc 代数 / marker/overlay 入口 /
;;;           edit-change / restrict / document-apply-descs-trusted / document-update-buffer
;;;   藏起来：content-* properties-* marker-table-* overlay-table-* vrow/layout/wrap/
;;;           render-* window-vrows / check-mode / snap-left-col / view 结构
;;;
;;; 两条数据流：
;;;   events → document-edit（唯一编辑入口，收 edit-*）→ 新 document + edit-change
;;;   buffer → render → run → window->screen → screen（后端画）
;;; ============================================================================

(require "text/point.rkt"
         "text/content.rkt"
         "text/buffer.rkt"
         "text/edit.rkt"
         "text/patch.rkt"
         "view/events.rkt"
         "view/width.rkt"
         "view/screen.rkt"
         "view/window.rkt"
         "view/view.rkt"
         "view/project.rkt"
         "view/document.rkt")

(provide
 ;; ---- point ----
 point point? struct:point point-line point-col
 point<? point=? point<=? pos<? pos=? pos<=? point-clamp
 ;; ---- edit-desc（唯一跨层契约）----
 edit-desc edit-desc? struct:edit-desc
 edit-desc-start edit-desc-end edit-desc-new-text
 edit-desc-map-position edit-desc-after-position edit-desc-inverse
 ;; ---- edit-change（一次编辑的完整材料）----
 edit-change edit-change? struct:edit-change
 edit-change-desc edit-change-inv edit-change-pre-point
 ;; ---- restrict（约束槽）----
 restrict restrict? struct:restrict make-restrict restrict-read-only?
 ;; ---- buffer —— 文档原子 ----
 buffer buffer? struct:buffer buffer-open buffer->string buffer->lines
 buffer-line-count buffer-line-ref
 buffer-apply-edit buffer-apply-edit-trusted buffer-edit
 edit-insert-char edit-insert edit-newline edit-backspace edit-delete edit-splice
 buffer-edit-desc-inverse
 buffer-put-property buffer-get-property buffer-remove-property buffer-put-properties-many
 buffer-put-restrict buffer-read-only-at? buffer-restrict-runs
 buffer-add-marker buffer-remove-marker buffer-marker-pos
 buffer-add-overlay buffer-remove-overlay
 buffer-content buffer-markers buffer-properties buffer-overlays
 buffer-tick buffer-modified?
 ;; ---- edit —— 批量 / 映射 / 变更行 ----
 buffer-apply-edit-batch edits-map-position edits-span
 ;; ---- patch —— 插件 delta ----
 patch patch? struct:patch patch-key patch-first-line patch-last-line patch-segs
 buffer-apply-patches buffer-content-eq?
 ;; ---- events —— 类型化输入 ----
 modifiers modifiers? struct:modifiers
 modifiers-control modifiers-alt modifiers-shift modifiers-meta
 text-event text-event? struct:text-event text-event-text text-event-modifiers
 key-event key-event? struct:key-event key-event-key key-event-modifiers
 mouse-press-event mouse-press-event? struct:mouse-press-event
 mouse-press-event-button mouse-press-event-x mouse-press-event-y mouse-press-event-modifiers
 mouse-wheel-event mouse-wheel-event? struct:mouse-wheel-event
 mouse-wheel-event-direction mouse-wheel-event-x mouse-wheel-event-y mouse-wheel-event-modifiers
 resize-event resize-event? struct:resize-event resize-event-rows resize-event-cols
 quit-event quit-event? struct:quit-event
 ;; ---- width ----
 char-display-width string-display-width index->column column->index snap-column-forward
 ;; ---- screen ----
 run run? struct:run run-col run-text run-face
 screen screen? struct:screen screen-rows screen-cols screen-row-runs
 screen-cursor-row screen-cursor-col
 make-screen screen-diff-rows screen-compose screen->text
 ;; ---- window ----
 window window? struct:window window-open
 window-buffer window-point window-height window-width window-mode
 window-top-line window-left-col window-top-seg
 window-set-buffer window-set-point window-set-mode window-set-top window-set-left
 window-set-top-seg window-set-size window-scroll window-hscroll window-goto
 window-left window-right window-home window-end
 window-ensure-point window-clamp-view window-visual-move window-up window-down
 window-point->screen window-screen->point window-scroll-visual
 ;; ---- project ----
 window->screen
 ;; ---- document —— 多视图容器 + 唯一编辑入口 ----
 document document? struct:document document-open document-of-buffer
 document->string document->lines document-line-count document-line-ref
 document-get-property document-read-only-at? document-restrict-runs
 document-add-view document-view-count document-window
 document-view-sync document-set-view-sync document-update-view document-sync-followers
 document-update-buffer document-put-property document-remove-property
 document-put-properties-many document-put-restrict document-apply-patches
 document-edit document-apply-descs-trusted document-buffer)

;;; ============================================================================
;;; 冒烟测试：门面 + 一条完整「属性 → 画面」链
;;; ============================================================================

(module+ test
  (require rackunit)

  (define b (buffer-open "hello\nworld"))
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  ;; 编辑闭环：document-edit（唯一入口）→ edit-change → 渲染
  (define-values (d0 _i0) (document-add-view (document-open (buffer->string b)) 2 10))
  (check-equal? (window-point (document-window d0 0)) (point 0 0))
  (define-values (d1 ch) (document-edit d0 0 (edit-insert-char #\X)))
  (check-equal? (document->string d1) "Xhello\nworld")
  (check-equal? (edit-change-desc ch) (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (window-point (document-window d1 0)) (point 0 1))
  (check-equal? (screen-rows (window->screen (document-window d1 0))) 2)

  ;; 属性 → run.face
  (define b3 (buffer-put-property b 0 0 5 'face 'keyword))
  (define s3 (window->screen (window-open b3 2 10)))
  (check-equal? (vector-ref (screen-row-runs s3) 0) (list (run 0 "hello" (hash 'face 'keyword))))

  ;; 编辑后属性随文本移动
  (define-values (d3 _i3) (document-add-view (document-of-buffer b3) 2 10))
  (define-values (d4 _) (document-edit d3 0 (edit-insert-char #\Z)))
  (check-equal? (vector-ref (screen-row-runs (window->screen (document-window d4 0))) 0)
                (list (run 0 "Z" (hash)) (run 1 "hello" (hash 'face 'keyword))))

  (displayln "api.rkt: all tests passed"))
