#lang racket

;;; ============================================================================
;;; api.rkt —— 低层公开面（原子 + 单元 + 文档 + 视口）
;;; ============================================================================
;;;
;;; 只透出**原子及其直接组合**：point / edit-desc / attr-desc / change / attrs /
;;; buffer / document / window / screen / events / width。
;;; 不含 compose 平台（editor-*）。
;;;
;;; 消费者白名单 = **core/editor.rkt**（原子 + editor 平台）；日常只用它。
;;; 本文件给需要单独拿低层值、或要下探 buffer/window 原语的场合。
;;;
;;; 门面**零逻辑**：只做显式白名单转发（新增内部函数不会自动泄漏）。
;;; 依赖方向：api ← 低层各层；platform 各模块直接 require 它们需要的层，api 不依赖 platform。
;;;
;;; 两条数据流：
;;;   内容流：op（buffer selection → edit-desc）→ document-apply-change → 新 document
;;;   渲染流：buffer → render → run → window->screen → screen（后端画）
;;; ============================================================================

(require "atom/point.rkt"
         "atom/content.rkt"
         "atom/edit.rkt"
         "atom/attr.rkt"
         "atom/change.rkt"
         "atom/selection.rkt"
         "atom/width.rkt"
         "atom/event.rkt"
         "unit/attrs.rkt"
         "unit/screen.rkt"
         "doc/buffer.rkt"
         "doc/document.rkt"
         "doc/batch.rkt"
         "viewport/window.rkt"
         "viewport/layout.rkt"
         "viewport/render.rkt"
         "viewport/project.rkt")

(provide
 ;; ---- point ----
 point point? struct:point point-line point-col
 point<? point=? point<=? pos<? pos=? pos<=? point-clamp
 ;; ---- edit-desc（唯一跨层文本变更契约）----
 edit-desc edit-desc? struct:edit-desc
 edit-desc-start edit-desc-end edit-desc-new-text
 edit-desc-map-position edit-desc-after-position edit-desc-inverse
 edits-normalize edits-map-position edits-span
 ;; ---- attr-desc（属性变更原子）----
 attr-desc attr-desc? struct:attr-desc
 attr-desc-start attr-desc-end attr-desc-key attr-desc-op attr-desc-val
 attr-set attr-remove attr-desc-empty?
 ;; ---- change（变更集：文本 + 属性）----
 change change? struct:change
 change-texts change-attrs change/edits change/attrs change-empty? change-text-only? change-attr-only?
 ;; ---- selection（选区：光标 + 影子）----
 selection selection? struct:selection selection-anchor selection-head
 caret selection-point caret-point selection-range selection-empty? caret?
 selection-set-head selection-set-anchor selection-map-head selection-map-anchor selection-map-both
 ;; ---- attrs（属性槽：通用 key→hash，随编辑移动）----
 attrs? attrs-empty attrs-line-count
 attrs-at attrs-runs attrs-key-runs attrs-range-runs
 attrs-apply-edit attrs-apply-attr attrs-apply-attr-batch attrs-attr-inverse attrs-check
 ;; ---- buffer —— 纯文本值（content ⊕ tick）----
 buffer? buffer-open buffer-content buffer->string buffer->lines
 buffer-line-count buffer-line-ref
 buffer-line-length buffer-clamp-point buffer-point->offset buffer-offset->point
 buffer-range-text buffer-clamp-edit-descs buffer-content-eq? buffer-tick
 buffer-op-insert-char buffer-op-insert buffer-op-newline buffer-op-backspace buffer-op-delete buffer-op-splice
 buffer-edit-desc-inverse
 ;; ---- document —— 可编辑根（buffer ⊕ attrs）----
 document? document-open document-buffer document-attrs
 document->string document->lines
 document-line-count document-line-ref document-line-length
 document-clamp-point document-point->offset document-offset->point document-range-text
 document-clamp-edit-descs document-tick document-attr-tick document-content-eq? document-attrs-eq?
 read-only-key attr-read-only?
 document-attr-at document-attr-runs document-attr-key-runs
 document-put-attr document-remove-attr
 document-apply-change document-apply-change-trusted
 document-apply-edit document-apply-edit-trusted document-edit document-edit-trusted
 change-result change-result? change-result-applied-texts change-result-applied-attrs
 change-result-text-inverses change-result-attr-inverses change-result-erased-restores
 change-result-replay change-result-undo
 ;; ---- edit —— 批量文本施加 ----
 document-apply-edit-batch document-apply-edit-batch-trusted
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
 screen? screen-rows screen-cols screen-row-runs
 screen-cursor-row screen-cursor-col screen-primary-cursor screen-cursors screen-selections screen-empty screen-diff-rows screen-compose screen->string
 ;; ---- window ----
 window? window-open
 window-document window-buffer window-point window-height window-width window-mode
 window-top-line window-left-col window-top-seg
 window-selections window-primary window-primary-index
 window-map-selections window-map-primary window-map-points
 window-set-document window-set-point window-set-selections window-add-selections window-remove-selections window-clamp-selections
 window-add-selection window-remove-selection window-set-primary window-set-primary-index window-selection-member?
 window-set-mode window-set-top-line window-set-left-col
 window-set-top-seg window-set-size window-vscroll window-hscroll
 window-left window-right window-home window-end
 point-left point-right point-home point-end
 window-ensure-point window-clamp-view window-visual-move point-up point-down window-up window-down
 window-point->screen window-screen->point window-scroll
 ;; ---- project / render ----
 window->screen)

;;; ============================================================================
;;; 冒烟测试：门面 + 一条完整「文档 → 画面」链
;;; ============================================================================

(module+ test
  (require rackunit)

  (define b (buffer-open "hello\nworld"))
  ;; buffer 基本读口
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  ;; 原子链：document → 编辑 → window → screen
  (define d (document-open "hello\nworld"))
  (define-values (d1 desc) (document-edit d (point 0 0) (buffer-op-insert-char #\X)))
  (check-equal? (document->string d1) "Xhello\nworld")
  (check-equal? desc (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? (screen-rows (window->screen (window-open d1 2 10))) 2)
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open d1 2 10))) 0)
                (list (run 0 "Xhello" (hash))))

  ;; 派生 face 由投影参数 provider 给出，不进文档
  (define (provider _b _line) (list (list 0 5 (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open d 2 10) provider)) 0)
                (list (run 0 "hello" (hash 'face 'keyword))))
  (check-equal? (vector-ref (screen-row-runs (window->screen (window-open d1 2 10))) 0)
                (list (run 0 "Xhello" (hash))))

  (displayln "api.rkt: all tests passed"))
