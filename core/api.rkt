#lang racket

;;; ============================================================================
;;; api.rkt —— 低层全量面（原子 + 单元 + 文档 + 视口）
;;; ============================================================================
;;;
;;; 只透出**原子及其直接组合**：point / edit-desc / buffer / window / screen / events / width。
;;; 不含 compose 平台（editor-*）。
;;;
;;; 消费者白名单 = **core/editor.rkt**（原子 + editor 平台）；日常只用它。
;;; 本文件给需要单独拿低层值、或要下探 buffer/window 原语的场合。
;;;
;;; 门面**零逻辑**：只做显式白名单转发（新增内部函数不会自动泄漏）。
;;; 依赖方向：api ← 低层各层；platform 各模块直接 require 它们需要的层，api 不依赖 platform。
;;;
;;; 两条数据流：
;;;   内容流：op（buffer point → edit-desc）→ buffer-apply-edit → 新 buffer
;;;   渲染流：buffer → render → run → window->screen → screen（后端画）
;;; ============================================================================

(require "atom/point.rkt"
         "atom/content.rkt"
         "atom/edit.rkt"
         "atom/restrict.rkt"
         "atom/selection.rkt"
         "atom/width.rkt"
         "atom/event.rkt"
         "unit/screen.rkt"
         "doc/buffer.rkt"
         "doc/batch.rkt"
         "viewport/window.rkt"
         "viewport/layout.rkt"
         "viewport/render.rkt"
         "viewport/project.rkt")

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
 edit-change-desc edit-change-inverse edit-change-pre-point
 ;; ---- selection（选区：光标 + 影子）----
 selection selection? struct:selection selection-anchor selection-head
 caret selection-point caret-point selection-range selection-empty? caret?
 selection-set-head selection-set-anchor selection-map-head selection-map-anchor selection-map-both
 ;; ---- restrict（约束槽）----
 restrict restrict? struct:restrict restrict-empty restrict-read-only?
 ;; ---- buffer —— 文档原子 ----
 buffer buffer? struct:buffer buffer-open buffer->string buffer->lines
 buffer-line-count buffer-line-ref
 buffer-line-length buffer-clamp-point buffer-point->offset buffer-offset->point
 buffer-apply-edit buffer-apply-edit-trusted buffer-edit buffer-edit-trusted
 edit-insert-char edit-insert edit-newline edit-backspace edit-delete edit-splice
 buffer-edit-desc-inverse
 buffer-range-text
 buffer-put-restrict buffer-remove-restrict buffer-restrict-at buffer-restrict-runs
 buffer-content buffer-content-eq? buffer-restrictions
 buffer-tick
 ;; ---- edit —— 批量 / 映射 / 变更行 ----
 buffer-apply-edit-batch buffer-apply-edit-batch-trusted edits-map-position edits-span
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
 cursor cursor? struct:cursor cursor-row cursor-col cursor-face cursor-primary?
 region region? struct:region region-row region-start-col region-end-col region-face
 screen screen? struct:screen screen-rows screen-cols screen-row-runs
 screen-cursor-row screen-cursor-col screen-primary-cursor screen-cursors screen-selections screen-empty screen-diff-rows screen-compose screen->string
 ;; ---- window ----
 window window? struct:window window-open
 window-buffer window-point window-height window-width window-mode
 window-top-line window-left-col window-top-seg
 window-selections window-primary window-primary-index
 window-map-selections window-map-primary window-map-points
 window-set-buffer window-set-point window-set-selections window-add-selections window-remove-selections window-map-points window-clamp-selections
 window-add-selection window-remove-selection window-set-primary window-set-primary-index window-selection-member?
 window-set-mode window-set-top-line window-set-left-col
 window-set-top-seg window-set-size window-vscroll window-hscroll
 window-left window-right window-home window-end
 point-left point-right point-home point-end
 window-ensure-point window-clamp-view window-visual-move point-up point-down window-up window-down
 window-point->screen window-screen->point window-scroll
 ;; ---- project / render ----
 window->screen
 no-face-provider)

;;; ============================================================================
;;; 冒烟测试：门面 + 一条完整「属性 → 画面」链
;;; ============================================================================

(module+ test
  (require rackunit)

  (define b (buffer-open "hello\nworld"))
  ;; buffer 基本读口
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  ;; 原子链：buffer → 编辑 → window → screen
  (define-values (b1 d1) (buffer-edit b (point 0 0) (edit-insert-char #\X)))
  (check-equal? (buffer->string b1) "Xhello\nworld")
  (check-equal? d1 (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (screen-rows (window->screen (window-open b1 2 10))) 2)
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open b1 2 10))) 0)
                (list (run 0 "Xhello" (hash))))

  ;; 派生 face 由投影参数 provider 给出，不进文档
  (define (provider _b _line) (list (list 0 5 (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open b 2 10) provider)) 0)
                (list (run 0 "hello" (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open b1 2 10))) 0)
                (list (run 0 "Xhello" (hash))))

  (displayln "api.rkt: all tests passed"))
