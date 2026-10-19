#lang racket

;;; editor/panel-ops.rkt —— panel 面的操作
;;;
;;; panel 是**无身份的值**，不可变；所以位置 / 大小 / view 槽 / 边框 / 深度 / face /
;;; 权重都不是原地写，而是返回新 panel，由宿主替换自己的 panel 列表项。
;;; 改完 rect / view 后照常调 editor/sync.rkt 的 panels-sync!，尺寸才会落进 view 的
;;; viewport。
;;;
;;; view 槽允许 #f（空面板）：本模块的操作都不要求 view 存在；panel-set-point! 在
;;; 空面板上返回 #f，不动。
;;;
;;; 分工：
;;;   · panel 值本身 / 内容区 / 命中 / 导航 / 几何坐标：view/panel.rkt（纯）；
;;;   · panel 面的操作：本模块（值变换纯 + 一个需要解包 view 的落点）；
;;;   · 尺寸写回：editor/sync.rkt 的 panels-sync!（唯一写入口）。

(require "ops.rkt" "query.rkt"
         "../view/panel.rkt"
         "../view/base/rect.rkt"
         "../text/base/point.rkt")

(provide
 ;; ---------- 值变换（纯） ----------
 panel-with-view                 ; panel view|#f → 新 panel
 panel-with-rect                 ; panel rect → 新 panel
 panel-shift                     ; panel dx dy → 新 panel（平移）
 panel-resize                    ; panel w h → 新 panel（左上角不动）
 panel-with-borders              ; panel borders → 新 panel
 panel-with-deep                 ; panel deep → 新 panel
 panel-with-face                 ; panel face → 新 panel
 panel-with-weight               ; panel weight → 新 panel

 ;; ---------- 落点 ----------
 panel-set-point!)               ; panel 屏幕格 (row,col) → view 主光标；→ 落点?

;;; ---------- 值变换（纯） ----------
;;
;; 这些函数不碰 buffer / view；原 panel 不变。view 槽可以是 #f。

(define (panel-with-view p v)
  (struct-copy panel p [view v]))

(define (panel-with-rect p r)
  (struct-copy panel p [rect r]))

;; 平移外框，尺寸不变。dx = 列方向，dy = 行方向。
(define (panel-shift p dx dy)
  (define r (panel-rect p))
  (panel-with-rect p (rect (+ (rect-x r) dx) (+ (rect-y r) dy)
                           (rect-w r) (rect-h r))))

;; 改外框尺寸，左上角不变。负尺寸夹到 0（与 rect-inset 一致）。
(define (panel-resize p w h)
  (define r (panel-rect p))
  (panel-with-rect p (rect (rect-x r) (rect-y r) (max 0 w) (max 0 h))))

(define (panel-with-borders p borders)
  (struct-copy panel p [borders borders]))

(define (panel-with-deep p deep)
  (struct-copy panel p [deep deep]))

(define (panel-with-face p face)
  (struct-copy panel p [face face]))

(define (panel-with-weight p weight)
  (struct-copy panel p [weight weight]))

;;; ---------- 落点 ----------

;; panel 的屏幕格 (row,col) → 把该 panel 的 view 主光标落到对应文档位置。
;; 内容外 / 不可见 / 空面板 → #f（不动）。鼠标“点哪落哪”一步到位。
(define (panel-set-point! p row col)
  (define-values (l c) (panel-screen-position->point p row col))
  (and l (begin (view-set-point! (panel-view p) (point l c)) #t)))
