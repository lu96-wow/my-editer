#lang racket

;;; layer  : core-render
;;; effect : 无（只 require/provide）

;;; edit-tui/core-render/main.rkt —— tui 渲染后端入口
;;;
;;; 把 core 的渲染值（`piece`）画成 racket-tui 序列；只产出序列，不自己输出。
;;; 边框 / 布局（panel → pane → screen）现在在 core 里，这里只管 piece → tui 序列。
;;; face 值（生产者/消费者共用）在 base/face.rkt；face 符号 → 样式在 theme/。

(provide (all-from-out "../base/face.rkt"
                       "render.rkt"))

(require "../base/face.rkt"
         "render.rkt")
