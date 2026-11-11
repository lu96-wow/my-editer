#lang racket

;;; 宿主装配 smoke test：不启动终端，只验证状态 / panel / 渲染一帧。

(require rackunit
         "../editor/host-api.rkt"
         "../host/final.rkt")

(define-values (ed state) (make-demo-editor))
(check-true (> (string-length (engine-view-text (editor-engine ed) 1)) 0))
(check-equal? (engine-view-point-line (editor-engine ed) 1) 0)

(define s (editor-state-with-area state (rect 0 0 40 10)))
(check-equal? (editor-focus-panel-id s) 'editor)
(check-equal? (length (editor-visible-editor-panels s)) 1)

(define-values (s1 cache bytes) (render-frame ed s #f))
(check-true (bytes? bytes))
(check-true (> (bytes-length bytes) 0))
(check-not-false cache)
;; 着色插件已写入 face track（define 是 keyword）。
(check-not-false (engine-view-face-at (editor-engine ed) 1 2 1))

;; 第二帧内容不变 -> 空差量（增量渲染命中）。
(define-values (_s2 _cache2 bytes2) (render-frame ed s1 cache))
(check-equal? (bytes-length bytes2) 0)

;;; split：新 panel 有自己的 view，焦点落到新 panel。
(define-values (s-split _a1) (editor-split! ed s 'right))
(check-equal? (length (editor-visible-editor-panels s-split)) 2)
(check-not-equal? (editor-focus-panel-id s-split) 'editor)
(check-not-false (engine-view-object (editor-engine ed)
                                     (editor-focus-view-id s-split)))
(define-values (s-split-rendered _c-split b-split) (render-frame ed s-split #f))
(check-true (> (bytes-length b-split) 0))
;; split 出来的新 view 也会拿到同一份 face track。
(check-not-false (engine-view-face-at (editor-engine ed)
                                      (editor-focus-view-id s-split-rendered)
                                      2 1))

;;; 方向 focus：从右 panel 回到左边 editor。
(define-values (s-focus _a2) (editor-focus! ed s-split 'left))
(check-equal? (editor-focus-panel-id s-focus) 'editor)

;;; close：删掉 split 出来的 panel / view，回到单 editor。
(define-values (s-close _a3) (editor-close! ed s-split))
(check-equal? (length (editor-visible-editor-panels s-close)) 1)
;; 关闭 panel 不再删 view；view / resource 保留，之后可以再 placement。
(check-not-false (engine-view-object (editor-engine ed) 10))
(check-not-false (editor-state-resource-for-view s-close 10))

(displayln "edit-tui-rebuild/test/host.rkt: ok")
