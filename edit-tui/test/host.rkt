#lang racket

;;; 宿主装配 smoke test：不启动终端，只验证状态 / panel / 渲染一帧。

(require rackunit
         "../editor/host-api.rkt"
         "../edit.rkt"
         "fixture.rkt")

;; 生产入口默认没有初始 resource；editor 只是一个空 buffer。
(define-values (empty-ed empty-state) (make-editor-app))
(check-equal? (resources-list (state-resources empty-state)) '())
(check-equal? (engine-view-text (editor-engine empty-ed) 1) "")
(check-equal? (state-resource-for-view empty-state 1) #f)

(define-values (ed state) (make-test-editor))
(check-true (> (string-length (engine-view-text (editor-engine ed) 1)) 0))
(check-equal? (engine-view-point-line (editor-engine ed) 1) 0)

(define s (state-with-screen state (rect 0 0 40 10)))
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

;;; split：只创建一个空 panel，不创建 / 复用 view，焦点落到新 panel。
(define-values (s-split _a1) (editor-split! ed s 'right))
(check-equal? (length (editor-visible-editor-panels s-split)) 2)
(check-not-equal? (editor-focus-panel-id s-split) 'editor)
(check-false (editor-focus-view-id s-split))
(check-false (engine-view-object (editor-engine ed) 10))
(define-values (_s-split-rendered _c-split b-split) (render-frame ed s-split #f))
(check-true (> (bytes-length b-split) 0))

;;; 方向 focus：从右 panel 回到左边 editor。
(define-values (s-focus _a2) (editor-focus! ed s-split 'left))
(check-equal? (editor-focus-panel-id s-focus) 'editor)

;;; close：删掉 split 出来的空 panel，回到单 editor。
(define-values (s-close _a3) (editor-close! ed s-split))
(check-equal? (length (editor-visible-editor-panels s-close)) 1)
(check-not-false (engine-view-object (editor-engine ed) 1))
(check-not-false (state-resource-for-view s-close 1))

;;; 最后一个 editor：不删 panel，只清空 views / active；buffer / resource 保留。
(define-values (s-editor _a4) (editor-focus! ed s-close 'right))
(check-equal? (editor-focus-panel-kind s-editor) 'editor)
(define-values (s-last _a5) (editor-close! ed s-editor))
(check-equal? (length (editor-visible-editor-panels s-last)) 1)
(check-false (editor-focus-view-id s-last))
(check-not-false (engine-view-object (editor-engine ed) 1))
(check-not-false (state-resource-for-view s-last 1))

(displayln "edit-tui/test/host.rkt: ok")
