#lang racket

;;; edit4/layout.rkt —— 布局层入口（只做再导出）
;;;
;;; 四个正交关注点，各在一个文件：
;;;   rect     矩形
;;;   size     尺寸意图 + 1-D 求解器（唯一的「难数学」）
;;;   tree     结构 + min + 手术
;;;   geometry 树 × 区域 → 矩形 + cuts
;;;   hit      命中 + 拖拽
;;;   float    正交覆盖层
;;;   frame    平铺+浮窗的完整几何 + 统一定序命中
;;;   settle   把解算结果写回树（规范化）
;;;   validate 不变量自检
;;;   cache    几何缓存（按输入身份失效）
;;;
;;; 布局层不认识 vid / document / border / face / plugin / command。

(provide (all-from-out "layout/rect.rkt"
                       "layout/size.rkt"
                       "layout/tree.rkt"
                       "layout/geometry.rkt"
                       "layout/hit.rkt"
                       "layout/float.rkt"
                       "layout/frame.rkt"
                       "layout/settle.rkt"
                       "layout/validate.rkt"
                       "layout/cache.rkt"))

(require "layout/rect.rkt"
         "layout/size.rkt"
         "layout/tree.rkt"
         "layout/geometry.rkt"
         "layout/hit.rkt"
         "layout/float.rkt"
         "layout/frame.rkt"
         "layout/settle.rkt"
         "layout/validate.rkt"
         "layout/cache.rkt")
