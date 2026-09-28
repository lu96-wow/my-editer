#lang racket

(require "base/change.rkt" "base/selection.rkt" "base/point.rkt")

;;; text/rebase.rkt —— 把选区过一串编辑（选区重基准）
;;;
;;; 输入：一串 change（都同一「编辑前」坐标系、两两不重叠）+ 一份 selections。
;;; 输出：映射后的 selections（已排序 / 去重 / 合并，primary 按身份追踪）。
;;;
;;; **不碰 document、不碰视口**：内容传播与滚动由调用方自己决定。
;;; 用途：非编辑者视图在同文档变更后重定位自己的选区（editor-edit 用 command-* 返回的
;;; changes 调 selections-rebase）；外部编辑同步。
;;;
;;; 两种语义：
;;;   selections-rebase   字面：每个端点随编辑平移；落在被删区间 → 吸附区间起点；
;;;                       恰在一次零宽插入的点上 → 不动（不跟随插入）。
;;;   selections-advance  前进：每个选区坍缩到 head，head 过全部编辑后；
;;;                       恰在零宽插入点上 → 落到插入文本之后（编辑者的光标）。

(provide
 ;; 字面重基准 / 前进重基准
 selections-rebase selections-advance)

;; 字面重基准：anchor / head 各自过编辑。
(define (selections-rebase changes ss)
  (selections-normalize
   (selections-map ss
                   (lambda (s)
                     (selection (changes-map-point-literal changes (selection-anchor s))
                                (changes-map-point-literal changes (selection-head s)))))))

;; 前进重基准：坍缩到 head，head 过编辑后（零宽插入 → 落到插入之后）。
(define (selections-advance changes ss)
  (selections-normalize
   (selections-map ss
                   (lambda (s) (caret (changes-map-point changes (selection-head s)))))))
