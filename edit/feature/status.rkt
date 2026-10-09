#lang racket

;;; edit/feature/status.rkt —— 状态窗口（底部，1 行）
;;;
;;; 显示**活动编辑视图**（粘性 edit-vid）：文档名 + 行:列。只读。
;;; 每帧由 panel refresh 重生成（内容没变则跳过）。

(require "api.rkt")

(provide status-install)

(define (status-text s)
  (define vid (session-edit-vid s))
  (define body
    (cond
      [(not vid) " edit"]
      [else
       (define did (session-view-did s vid))
       (define name (session-document-name s did))
       (format " ~a   ~a:~a" name
               (add1 (session-view-point-line s vid))
               (add1 (session-view-point-column s vid)))]))
  (define pfx (session-prefix s))
  (string-append body (if pfx (format "  [~a]" (prefix-label pfx)) "")))

;; → (values session vid)
(define (status-install s width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*status*"))
  (define last (box #f))
  (define p (panel 'status vid
                   (lambda (s)
                     (define t (status-text s))
                     (cond [(equal? t (unbox last)) #f]
                           [else (set-box! last t) (panel-doc (list (list t #f)))]))
                   #f      ; keys
                   'bottom ; group（与 input / log 同位置互斥）
                   1))
  (values (session-add-panel s1 p) vid))
