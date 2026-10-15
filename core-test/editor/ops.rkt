#lang racket

;;; core/editor/ops.rkt —— 提交壳：编辑 / 多视图重基准 / undo 事务 / 导航 / 视口 / CAS。
(require rackunit
         "../../core/editor.rkt"
         (only-in "../../core/editor/state.rkt" buffer-document))

;;; ---------- 编辑提交 + 多视图重基准 ----------
(define b (make-buffer "abc\ndef"))
(define v  (buffer-add-view! b 20 4 #:line-numbers? #f))
(define v2 (buffer-add-view! b 20 4
                             #:selections (selections-one (caret (point 0 2)))))

(define chs (buffer-edit! b v (op-type "X")))
(check-equal? (length chs) 1)
(check-equal? (buffer-string b) "Xabc\ndef")
(check-equal? (view-point v) (point 0 1))         ; 发起视图前进
(check-equal? (view-point v2) (point 0 3))        ; 兄弟视图按 changes 重基准
(check-true (buffer-can-undo? b))

;; 无变更 → '()，不记步、文档不变
(define before (buffer-document b))
(check-equal? (buffer-edit! b v (op-type "")) '())
(check-eq? (buffer-document b) before)

;; 只读守：光标处只读 → 整体拒绝、返回 #f
(buffer-readonly-range! b (range (point 0 0) (point 0 1)) #t)
(view-set-point! v (point 0 0))
(check-false (buffer-edit! b v (op-type "Z")))
(check-equal? (buffer-string b) "Xabc\ndef")
;; -ignore-readonly 绕过
(check-equal? (length (buffer-edit! b v (op-type-ignore-readonly "Z"))) 1)
(check-equal? (buffer-string b) "ZXabc\ndef")

;;; ---------- undo / redo ----------
(check-true (buffer-undo! b))                     ; 撤销 Z
(check-equal? (buffer-string b) "Xabc\ndef")
(check-equal? (buffer-undo-target b) "abc\ndef")
(check-true (buffer-redo! b))
(check-equal? (buffer-string b) "ZXabc\ndef")
(check-false (buffer-can-redo? b))              ; redo 后没有 future

;;; ---------- undo 事务（显式合并） ----------
(define b2 (make-buffer "abcdef"))
(define w (buffer-add-view! b2 20 4))
(view-set-point! w (point 0 1))
(void (buffer-with-undo-step b2
        (lambda ()
          (buffer-edit! b2 w (op-type "X"))             ; aXbcdef
          (check-true (buffer-can-undo? b2))            ; 事务内首提交即落栈
          (check-equal? (buffer-depth b2) 1)
          (buffer-edit! b2 w (op-type "Y")))))          ; aXYbcdef
(check-equal? (buffer-string b2) "aXYbcdef")
(check-equal? (buffer-depth b2) 1)                ; 合成一步
(check-true (buffer-undo! b2))
(check-equal? (buffer-string b2) "abcdef")

;; begin/end：嵌套计数，最外层 end 才收；期间多次编辑并进同一步
(define b3 (make-buffer "abc"))
(define w3 (buffer-add-view! b3 10 4))
(buffer-begin-undo-step! b3)
(buffer-begin-undo-step! b3)
(void (buffer-edit! b3 w3 (op-type "A")))
(buffer-end-undo-step! b3)
(void (buffer-edit! b3 w3 (op-type "B")))                ; 仍在外层事务内
(buffer-end-undo-step! b3)
(check-equal? (buffer-depth b3) 1)
(check-equal? (buffer-string b3) "ABabc")

;;; ---------- 整篇 / 区间 / 行 / 格 ----------
(define b4 (make-buffer "abc\ndef"))
;; set-document!：程序整篇替换，默认不记步
(void (buffer-set-document! b4 "xyz"))
(check-equal? (buffer-string b4) "xyz")
(check-false (buffer-can-undo? b4))
;; 事务内 set-document! 算进该步
(void (buffer-with-undo-step b4 (lambda () (buffer-set-document! b4 "pqr"))))
(check-equal? (buffer-string b4) "pqr")
(check-true (buffer-can-undo? b4))
(check-true (buffer-undo! b4))
(check-equal? (buffer-string b4) "xyz")

;; replace-range! 记一步
(define b5 (make-buffer "abcdef"))
(check-equal? (length (buffer-replace-range! b5 (range (point 0 1) (point 0 3)) "XY")) 1)
(check-equal? (buffer-string b5) "aXYdef")
(check-true (buffer-can-undo? b5))

;; set-line! / set-char!：越界 → #f，否则记一步
(define b6 (make-buffer "abc\ndef"))
(check-equal? (length (buffer-set-line! b6 0 "ZZ")) 1)
(check-equal? (buffer-string b6) "ZZ\ndef")
(check-false (buffer-set-line! b6 5 "x"))
(check-false (buffer-set-char! b6 0 9 #\x))
(check-equal? (length (buffer-set-char! b6 0 0 #\Q)) 1)
(check-equal? (buffer-string b6) "QZ\ndef")

;;; ---------- CAS：base 未变才装 ----------
(define b7 (make-buffer "abc"))
(define stale (buffer-document b7))
(void (buffer-set-document! b7 "changed"))
(check-false (buffer-commit-if-unchanged! b7 stale (buffer-document b7)))  ; base 过期
(define b8 (make-buffer "abc"))
(check-true (buffer-commit-if-unchanged! b8 (buffer-document b8) (buffer-document (make-buffer "new"))))
(check-equal? (buffer-string b8) "new")
(check-true (buffer-can-undo? b8))

;;; ---------- 导航提交 ----------
(define bn (make-buffer "abc\ndef"))
(define vn (buffer-add-view! bn 20 4))
(view-set-point! vn (point 0 1))
(view-right! vn)                (check-equal? (view-point vn) (point 0 2))
(view-end! vn)                  (check-equal? (view-point vn) (point 0 3))
(view-down! vn)                 (check-equal? (view-point vn) (point 1 3))
(view-home! vn)                 (check-equal? (view-point vn) (point 1 0))
(view-left! vn)                 (check-equal? (view-point vn) (point 0 3))
;; extend：只动 head
(view-set-point! vn (point 0 1))
(view-right! vn #t)
(check-equal? (view-primary-range vn) (range (point 0 1) (point 0 2)))

;;; ---------- 选区提交 ----------
(define bs (make-buffer "abc\ndef"))
(define vs (buffer-add-view! bs 20 4))
(view-select-all! vs)
(check-equal? (view-primary-range vs) (range (point 0 0) (point 1 3)))
(view-set-point! vs (point 0 1))
(view-add-selection! vs (caret (point 1 1)))
(check-equal? (view-selection-count vs) 2)
(view-remove-selection! vs (caret (point 1 1)))
(check-equal? (view-selection-count vs) 1)
(view-set-point! vs (point 99 99))                ; clamp 到合法域
(check-equal? (view-point vs) (point 1 3))

;;; ---------- 视口提交 ----------
(define bv (make-buffer (string-join (for/list ([i (in-range 20)]) (format "l~a" i)) "\n")))
(define vv (buffer-add-view! bv 10 3))
(view-set-point! vv (point 10 0))
(check-equal? (view-anchor-point vv) (point 8 0)) ; 10 - 3 + 1
(view-scroll! vv 2)
(check-equal? (view-anchor-point vv) (point 10 0))
(view-scroll! vv -100)
(check-equal? (view-anchor-point vv) (point 0 0))
(view-toggle-line-numbers! vv)
(check-true (view-line-numbers? vv))
(view-set-mode! vv 'wrap)
(check-equal? (view-mode vv) 'wrap)
(view-resize! vv 6 4)
(check-equal? (view-width vv) 6)
(check-equal? (view-height vv) 4)

;;; ---------- 锚点 / ensure ----------
(define ba (make-buffer "abcdefghij\nshort"))
(define va (buffer-add-view! ba 4 2))
(view-scroll-to-column! va 6)
(check-equal? (view-anchor-point va) (point 0 6))
(view-scroll-to-point! va (point 1 0))
(check-equal? (view-anchor-point va) (point 1 0))
;; ensure 并返回主光标屏幕位置
(define be (make-buffer (string-join (for/list ([i (in-range 10)]) (format "l~a" i)) "\n")))
(define ve (buffer-add-view! be 10 3))
(view-set-point! ve (point 5 0))
(check-equal? (call-with-values (λ () (view-ensure-cursor-position! ve)) list) '(2 0))

;;; ---------- 历史开关 / 清空 ----------
(define bh (make-buffer "abc"))
(define vh (buffer-add-view! bh 10 4))
(void (buffer-edit! bh vh (op-type "X")))
(check-true (buffer-can-undo? bh))
(buffer-set-history-enabled! bh #f)
(check-false (buffer-can-undo? bh))
(buffer-set-history-enabled! bh #t)
(check-true (buffer-can-undo? bh))                  ; past 未被丢弃
(buffer-clear-history! bh)
(check-false (buffer-can-undo? bh))
(check-false (buffer-can-redo? bh))
(void (buffer-edit! bh vh (op-type "Y")))
(check-true (buffer-can-undo? bh))
(buffer-reset-history! bh #f)                       ; 清历史 + 关记步
(check-false (buffer-can-undo? bh))
(check-false (buffer-history-enabled? bh))

;;; ---------- 复制 ----------
(define bc (make-buffer "abc\ndef"))
(define vc (buffer-add-view! bc 20 4))
(view-set-selections! vc (selections-one (selection (point 0 0) (point 1 2))))
(check-equal? (view-copy-text vc) "abc\nde")
(check-equal? (view-selection-text vc (caret (point 0 1))) "")

(displayln "editor/ops.rkt: ok")
