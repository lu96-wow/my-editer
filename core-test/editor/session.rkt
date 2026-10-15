#lang racket

;;; core/editor/session.rkt —— 交互会话：连续编辑合成一步；打断动作先收步。
(require rackunit
         "../../core/editor.rkt")

;; ---------- 连续编辑 = 一步 ----------
(define b (make-buffer "abcdef"))
(define v (buffer-add-view! b 20 4))
(view-set-point! v (point 0 3))
(define s (make-edit-session b))

(void (session-edit! s v (op-type "X")))            ; abcXdef
(void (session-edit! s v (op-type "Y")))            ; abcXYdef
(check-equal? (buffer-string b) "abcXYdef")
(check-equal? (buffer-depth b) 1)             ; 还开着也已可见
(check-true (buffer-can-undo? b))

;; break 收步 → 下一次编辑成新步
(session-break! s)
(void (session-edit! s v (op-type "Z")))            ; abcXYZdef
(check-equal? (buffer-depth b) 2)

;; 导航先收步：之后的编辑另起一步
(session-left! s v)                          ; 光标 (0,5)
(void (session-edit! s v (op-type "W")))            ; abcXYWZdef
(check-equal? (buffer-string b) "abcXYWZdef")
(check-equal? (buffer-depth b) 3)

;; undo 走 session（先收步再执行）
(check-true (session-undo! s))
(check-equal? (buffer-string b) "abcXYZdef")
(check-equal? (buffer-depth b) 2)

;; ---------- 程序写镜像：先收步 → 独立成步 ----------
(define b2 (make-buffer "abcdef"))
(define v2 (buffer-add-view! b2 20 4))
(define s2 (make-edit-session b2))
(void (session-edit! s2 v2 (op-type "X")))          ; 打字步
(void (session-replace-range! s2 (range (point 0 0) (point 0 1)) "A"))   ; 收步 + 记一步
(check-equal? (buffer-depth b2) 2)
(check-equal? (buffer-string b2) "Aabcdef")

;; ---------- 生命周期 / 历史镜像不崩 ----------
(define b3 (make-buffer "abc"))
(define v3 (buffer-add-view! b3 10 4))
(define s3 (make-edit-session b3))
(session-set-history-enabled! s3 #f)
(check-false (buffer-history-enabled? b3))
(session-reset-history! s3)
(check-true (buffer-history-enabled? b3))
(session-close-view! s3 v3)
(check-equal? (buffer-views b3) '())
(session-close! s3)

(displayln "editor/session.rkt: ok")
