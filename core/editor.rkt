#lang racket

;;; editor.rkt —— 对外使用层（buffer / view 操作）
;;;
;;; 实现层在 editor/{state,ops,query,attributes,render}.rkt，保持原样。
;;; 本模块只做两件事：
;;;   1. 用 rename-out 把「实现名」暴露成「意图名」（如 view-set-top-line! → view-scroll-to-line!）；
;;;   2. 只再导出 buffer/view 的操作与必要值词汇，隐藏内部构造
;;;      （track / viewport / history / slot / edit-op 字段 / document 值 …）。
;;;
;;; 于是宿主 require 本模块即可，不必知道内部表示。
;;; 需要扩展机制（自定义 edit-op、槽、track 读写）时，直接 require 对应实现模块。

(require "editor/state.rkt"
         "editor/ops.rkt"
         "editor/query.rkt"
         "editor/attributes.rkt"
         "editor/render.rkt"
         ;; 值词汇表（宿主构造 point / range / selection / 读 screen 用）
         "text/base/point.rkt"
         "text/base/selection.rkt"
         "text/base/range.rkt"
         "text/base/change.rkt"
         "view/base/screen.rkt"
         "view/compose.rkt"
         "view/patch.rkt")

(provide
 ;; ==================== 对象 / 生命周期 ====================
 make-buffer                      ; text [name] → buffer
 buffer-add-view!                 ; buffer w h [#:mode #:line-numbers? #:selections] → view
 buffer-close-view!               ; buffer view → void
 buffer-close!                    ; buffer → void
 buffer-set-name!                 ; buffer name → void
 buffer-name
 buffer-views
 view-buffer
 view-selections
 buffer? view?

 ;; ==================== 编辑 ====================
 op-type op-type-ignore-readonly
 op-backspace op-backspace-ignore-readonly
 op-delete op-delete-ignore-readonly
 op-paste op-paste-ignore-readonly
 buffer-edit!                     ; buffer view op [#:ensure?] → #f | (listof change)
 buffer-replace!                  ; buffer value [#:ensure? #:changes] → void
 (rename-out [buffer-apply-if-version! buffer-commit-if-unchanged!])  ; → applied?
 (rename-out [buffer-seal!             buffer-end-undo-step!])        ; 切断并步

 ;; ==================== 光标 / 选区 ====================
 view-nav!                        ; view f [extend?] [#:ensure?]
 view-left! view-right! view-up! view-down! view-home! view-end!
 view-set-selections! view-set-point! view-select-all!
 view-copy-text

 ;; ==================== 视口（意图名） ====================
 (rename-out [view-set-top-line!     view-scroll-to-line!])     ; view line → void
 (rename-out [view-set-left-column!  view-scroll-to-column!])   ; view column → void
 (rename-out [view-set-anchor-point! view-scroll-to-point!])    ; view point → void
 view-scroll! view-ensure! view-ensure-cursor-position!
 view-set-mode! view-toggle-line-numbers! view-resize!

 ;; ==================== 属性 ====================
 buffer-face-range! buffer-readonly-range!
 buffer-face-cell! buffer-readonly-cell!
 buffer-face-line! buffer-readonly-line!
 buffer-face-batch! buffer-readonly-batch!
 buffer-face-range-batch! buffer-readonly-range-batch!

 ;; ==================== 历史 ====================
 buffer-undo! buffer-redo! buffer-clear-history! buffer-reset-history!
 buffer-set-history-enabled!
 buffer-can-undo? buffer-can-redo? buffer-depth buffer-history-enabled?

 ;; ==================== 查询 ====================
 buffer-string view-string
 buffer-range-text view-range-text
 buffer-char-at view-char-at
 buffer-face-at buffer-readonly-at? view-face-at view-readonly-at?
 view-point view-point-line view-point-column
 view-primary view-primary-range view-selection-count
 view-cursor-screen-position view-point->screen-position view-screen-position->point
 view-mode view-line-numbers? view-width view-height
 view-visible-range view-anchor-point

 ;; ==================== 渲染 ====================
 (struct-out display-entry)
 display-entry-cursor-position
 render-display render-display-patch

 ;; ==================== 值词汇：点 / 区间 / 选区 / 变更 ====================
 point point? point-line point-column
 point<? point=? point<=?
 range range? range-of range-start range-end range-normalize range-empty?
 caret caret? selection selection? selection-point selection-range selection-empty?
 selection-anchor selection-head
 selection-go selection-extend selection-normalize
 selections selections? selections-one selections-of
 selections-count selections-items selections-primary selections-primary-index
 selections-add selections-remove selections-set-primary selections-map
 selections-go selections-extend selections-normalize selections-dedupe selections-clamp
 change change? change-kind change-before change-after change-empty?

 ;; ==================== 值词汇：屏幕 / 合成 ====================
 (struct-out run) (struct-out cursor) (struct-out region) (struct-out screen)
 screen-row screen->string
 (struct-out pane)
 (struct-out piece))
