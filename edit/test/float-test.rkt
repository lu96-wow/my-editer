#lang racket

;;; edit/test/float-test.rkt —— 浮动窗口能力验证（headless）
;;;
;;;   raco test edit/test/float-test.rkt
;;;
;;; 覆盖：注册 / dock 认同 / 自带键表 / 进入几何(deep) / 鼠标命中优先 /
;;;       buffers 去重 / 关闭还原焦点。

(require rackunit
         "../demo.rkt"
         "../session.rkt"
         "../command/command.rkt"
         "../feature/api.rkt"
         "../core/layout.rkt")

(define s (demo-session 80 24))

;; 一个编辑视图，取它的光标屏幕坐标作锚点
(define-values (s1 edid evid) (session-add-document s "hello\nworld" 40 18 #:name "*ed*"))
(define s2 (session-show-view s1 evid))
(define-values (ac ar) (session-view-cursor-screen s2 evid))
(check-pred exact-integer? ac)
(check-pred exact-integer? ar)
;; 锚点应在编辑区里（demo layout-left 的侧栏宽 26）
(check-pred (lambda (c) (>= c 26)) ac)

;; 浮层：独立文档 / 视图 + 自己的键表
(define-values (s3 fdid fvid) (session-add-document s2 "a\nbb\nccc" 12 3 #:name "*pop*"))
(define fkeys (kbd (key 'down) (cmd-nav 'down #f)))
(define s4 (session-float-open s3 (float fvid fkeys ac ar 12 3 1000)))

(check-true (and (session-float s4 fvid) #t))
(check-true (session-dock-vid? s4 fvid))          ; 视作 docked
(check-equal? (session-vid-keys s4 fvid) fkeys)   ; 自带键表优先生效
(check-equal? (session-focus-vid s4) fvid)
(check-equal? (session-edit-vid s4) evid)         ; 粘性活动编辑视图不变

;; 进入几何：浮层在 session-panes 里，deep 高
(define fp (for/first ([p (in-list (session-panes s4))] #:when (eqv? (placed-vid p) fvid)) p))
(check-true (and fp #t))
(check-equal? (placed-x fp) ac)
(check-equal? (placed-y fp) ar)
(check-equal? (placed-deep fp) 1000)
(check-equal? (session-view-at s4 ac ar) fvid)    ; 鼠标命中：浮层压过编辑区

;; buffers 去重（浮层文档不算缓冲区）
(check-true (and (memv fdid (session-float-dids s4)) #t))

;; 关闭：登记撤销、几何消失、焦点还原到编辑视图
(define s5 (session-float-close s4 fvid))
(check-false (session-float s5 fvid))
(check-false (for/first ([p (in-list (session-panes s5))] #:when (eqv? (placed-vid p) fvid)) #t))
(check-equal? (session-focus-vid s5) evid)
