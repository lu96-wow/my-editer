#lang racket

;;; UI view 写回：
;;;   · 只改 selection face -> 不碰文本，buffer version 不变
;;;   · 文本变化 -> 最小文本替换，face 重新对齐
;;;   · 完全没变 -> no-op

(require rackunit
         "../editor/host-api.rkt")

(define e (make-engine))
(void (engine-create-buffer! e 1 "test" "aa\nbb\ncc"))
(void (engine-create-view! e 1 1))

(check-true (engine-set-view-content! e 1
                                      '("aa" "bb" "cc")
                                      '(face-a face-b face-c)))
(define v0 (engine-doc-version e 1))

;; face-only：选中行变化，文本 identity 不变。
(check-true (engine-set-view-content! e 1
                                      '("aa" "bb" "cc")
                                      '(face-a face-selected face-c)))
(check-eq? (engine-doc-version e 1) v0)
(check-equal? (engine-view-text e 1) "aa\nbb\ncc")
(check-equal? (engine-view-face-at e 1 0 0) 'face-a)
(check-equal? (engine-view-face-at e 1 1 0) 'face-selected)
(check-equal? (engine-view-face-at e 1 2 0) 'face-c)

;; 重复写完全相同的内容：no-op。
(check-false (engine-set-view-content! e 1
                                       '("aa" "bb" "cc")
                                       '(face-a face-selected face-c)))
(check-eq? (engine-doc-version e 1) v0)

;; 文本变化：只替换变化区间，但最终文本 / face 对齐。
(define v1 (engine-doc-version e 1))
(check-true (engine-set-view-content! e 1
                                      '("aa" "bx" "cc")
                                      '(face-a face-selected face-c)))
(check-not-eq? (engine-doc-version e 1) v1)
(check-equal? (engine-view-text e 1) "aa\nbx\ncc")
(check-equal? (engine-view-face-at e 1 0 0) 'face-a)
(check-equal? (engine-view-face-at e 1 1 0) 'face-selected)
(check-equal? (engine-view-face-at e 1 2 0) 'face-c)

;; 插入一行：face 随新行重新对齐。
(check-true (engine-set-view-content! e 1
                                      '("aa" "new" "bx" "cc")
                                      '(face-a face-new face-selected face-c)))
(check-equal? (engine-view-text e 1) "aa\nnew\nbx\ncc")
(check-equal? (engine-view-face-at e 1 1 0) 'face-new)
(check-equal? (engine-view-face-at e 1 2 0) 'face-selected)

;; 清空：文本和 face 都回到空。
(check-true (engine-set-view-content! e 1 '() '()))
(check-equal? (engine-view-text e 1) "")
(check-false (engine-view-face-at e 1 0 0))

(displayln "edit-tui/test/ui-incremental.rkt: ok")
