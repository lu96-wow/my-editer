#lang racket

;;; edit/surface/surface.rkt —— 面（surface）：可显示 / 可聚焦 / 可接管输入的一块东西
;;;
;;; 局部问题：panel（停靠面板）和 overlay（浮动窗口）其实是一回事 —— 都是
;;; 「一块有身份、有内容、有落位、可能接键的视图」。区别只在 **placement**：
;;;
;;;     dock  占根布局的命名区域（region / axis / size）
;;;     float 摆在锚点旁的浮动矩形（每帧算 pos）
;;;
;;; 内容是一份只读文档（content 生成），键 / 鼠标 / 滚动 / 关闭是可选行为。
;;; 于是「补全弹窗」「文档弹窗」「文件树」「状态行」都只是 surface 的不同实例 +
;;; 不同组合（见各组合处），不再是三套各写一遍的机制（panel / deco+overlay / layer）。
;;;
;;; 本模块是纯值：不认识 session，行为过程收到 session 由调用方传入。

(provide (struct-out surface) (struct-out dock) (struct-out float)
         surface? surface-dock? surface-float?
         dock-surface float-surface)

;;; ---------- 落位 ----------

(struct dock (region axis size) #:transparent)
;; region : slot-id             所在框架区域（同区域互斥 / Tab 互换 / 按 id 选中）
;; axis   : 'width | 'height    尺寸沿哪个轴
;; size   : positive-integer | 'flex

(struct float (pos deep) #:transparent)
;; pos  : session -> (or/c (list x y w h) #f)  每帧算矩形；#f = 本帧不显示
;; deep : integer                              叠放深度（大 = 在上）

;;; ---------- 面 ----------

(struct surface (id vid kind content placement keys mouse scroll on-close)
  #:transparent)
;; id        : symbol
;; vid       : vid
;; kind      : 'dock | 'float
;; content   : session -> (or/c document #f)   #f = 不自动刷新
;; placement : dock | float
;; keys      : keymap | #f                      聚焦时生效的键表
;; mouse     : (session vid col row -> (or/c session #f)) | #f
;; scroll    : (session vid delta -> session) | #f
;; on-close  : (session -> session) | #f

(define (surface-dock? s) (eq? 'dock (surface-kind s)))
(define (surface-float? s) (eq? 'float (surface-kind s)))

;;; ---------- 构造 ----------

(define (dock-surface id vid content keys region axis size)
  (surface id vid 'dock content (dock region axis size) keys #f #f #f))

(define (float-surface id vid content placement keys mouse scroll on-close)
  (surface id vid 'float content placement keys mouse scroll on-close))
